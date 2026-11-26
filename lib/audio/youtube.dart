import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:webview_windows/webview_windows.dart';

import '../platform.dart';

/// Spielt YouTube-Links über den offiziellen YouTube-Player ab – unsichtbar
/// im Hintergrund (WebView2), nur der Ton ist zu hören.
/// Videos, deren Kanal das Einbetten verbietet, lassen sich nicht abspielen.
class YoutubePlayer {
  YoutubePlayer._();
  static final YoutubePlayer instance = YoutubePlayer._();

  static const _host = 'lernspiel.player';

  WebviewController? _c;
  Future<bool>? _init;
  StreamSubscription<dynamic>? _sub;

  // Ersatzweg für Videos, die das Einbetten verbieten: normale YouTube-Seite
  // unsichtbar im Hintergrund (wie ein versteckter Browser-Tab).
  WebviewController? _w;
  Future<bool>? _wInit;
  StreamSubscription<dynamic>? _wSub;

  /// Wird aufgerufen, wenn ein Video zu Ende ist.
  VoidCallback? onEnded;

  /// Fehlercode des YouTube-Players (101/150 = Einbetten verboten).
  void Function(int code)? onError;

  /// Titel des gerade laufenden Videos.
  void Function(String title)? onTitle;

  /// Liest Video- oder Playlist-ID aus einem Link.
  static ({String? video, String? list})? parse(String text) {
    final u = Uri.tryParse(text.trim());
    if (u == null || u.scheme != 'https') return null;
    final host = u.host.toLowerCase();
    const hosts = {'youtube.com', 'www.youtube.com', 'm.youtube.com', 'music.youtube.com', 'youtu.be'};
    if (!hosts.contains(host)) return null;
    final idOk = RegExp(r'^[A-Za-z0-9_-]{6,64}$');
    String? video;
    if (host == 'youtu.be') {
      video = u.pathSegments.isNotEmpty ? u.pathSegments.first : null;
    } else if (u.pathSegments.length >= 2 &&
        const {'shorts', 'embed', 'live'}.contains(u.pathSegments.first)) {
      video = u.pathSegments[1];
    } else {
      video = u.queryParameters['v'];
    }
    var list = u.queryParameters['list'];
    if (video != null && !idOk.hasMatch(video)) video = null;
    if (list != null && !idOk.hasMatch(list)) list = null;
    if (video == null && list == null) return null;
    return (video: video, list: list);
  }

  /// YouTube-Wiedergabe nutzt WebView2 und geht nur unter Windows.
  static bool get supported => isWindows;

  Future<bool> _ensure() => supported ? (_init ??= _create()) : Future.value(false);

  Future<bool> _create() async {
    try {
      final dir = Directory('${Directory.systemTemp.path}${Platform.pathSeparator}fi_lernspiel_yt');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      File('${dir.path}${Platform.pathSeparator}player.html').writeAsStringSync(_html);
      // Autoplay ohne Klick in die Webseite erlauben (Klick war ja im Spiel)
      await WebviewController.initializeEnvironment(
        userDataPath: '${dir.path}${Platform.pathSeparator}profile',
        additionalArguments: '--autoplay-policy=no-user-gesture-required',
      );
      final c = WebviewController();
      await c.initialize();
      await c.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
      await c.addVirtualHostNameMapping(_host, dir.path, WebviewHostResourceAccessKind.allow);
      _sub = c.webMessage.listen(_onMessage, onError: (_) {});
      await c.loadUrl('https://$_host/player.html');
      _c = c;
      return true;
    } catch (e) {
      debugPrint('YouTube-Player nicht verfügbar: $e');
      _init = null;
      return false;
    }
  }

  void _onMessage(dynamic m) {
    if (m is! Map) return;
    switch (m['t']) {
      case 'ended':
        onEnded?.call();
      case 'error':
        onError?.call((m['code'] as num?)?.toInt() ?? -1);
      case 'playing':
        final t = m['title'];
        if (t is String && t.isNotEmpty) onTitle?.call(t);
    }
  }

  Future<bool> _ensureWatch() => _wInit ??= _createWatch();

  Future<bool> _createWatch() async {
    try {
      if (!await _ensure()) return false; // Umgebung initialisieren
      final w = WebviewController();
      await w.initialize();
      await w.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
      await w.addScriptToExecuteOnDocumentCreated(_watchScript);
      _wSub = w.webMessage.listen(_onMessage, onError: (_) {});
      _w = w;
      return true;
    } catch (e) {
      debugPrint('YouTube-Seite nicht verfügbar: $e');
      _wInit = null;
      return false;
    }
  }

  /// Video über die normale YouTube-Seite abspielen (Ersatzweg).
  Future<bool> playWatchPage(String link, double volume) async {
    final id = parse(link);
    if (id?.video == null) return false;
    if (!await _ensureWatch()) return false;
    await _run('ytStop()'); // Einbett-Player still
    try {
      await _w!.loadUrl('https://www.youtube.com/watch?v=${id!.video}&vol=${(volume * 100).round()}');
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _stopWatch() async {
    final w = _w;
    if (w == null) return;
    try {
      await w.loadUrl('about:blank');
    } catch (_) {}
  }

  Future<bool> play(String link, double volume) async {
    final id = parse(link);
    if (id == null) return false;
    if (!await _ensure()) return false;
    await _stopWatch();
    final v = (volume * 100).round();
    final js = id.video != null
        ? 'ytPlay(${jsonEncode(id.video)}, null, $v)'
        : 'ytList(${jsonEncode(id.list)}, $v)';
    try {
      await _c!.executeScript(js);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _run(String js) async {
    final c = _c;
    if (c == null) return;
    try {
      await c.executeScript(js);
    } catch (_) {}
  }

  Future<void> stop() async {
    await _run('ytStop()');
    await _stopWatch();
  }

  Future<void> setVolume(double v) async {
    await _run('ytVol(${(v * 100).round()})');
    final w = _w;
    if (w != null) {
      try {
        await w.executeScript('window.__ytVol = $v;');
      } catch (_) {}
    }
  }

  void dispose() {
    _sub?.cancel();
    _wSub?.cancel();
    _c?.dispose();
    _w?.dispose();
  }

  /// Läuft auf der YouTube-Seite: Cookie-Hinweis ablehnen (datensparsam),
  /// Video starten, Lautstärke setzen, Ende und Titel melden.
  static const _watchScript = r'''
(function () {
  if (window.__lernspiel) return; window.__lernspiel = true;
  const q = new URLSearchParams(location.search);
  if (window.__ytVol === undefined) window.__ytVol = (parseInt(q.get('vol') || '50') || 50) / 100;
  function post(o) { try { window.chrome.webview.postMessage(o); } catch (e) {} }
  let sentTitle = '';
  // Ziel-Video merken: nach dem Cookie-Hinweis leitet YouTube oft zur Startseite um
  try {
    if (location.pathname === '/watch') localStorage.setItem('__lsTarget', location.href);
  } catch (e) {}
  setInterval(function () {
    // Cookie-Hinweis (eigene Seite oder Dialog über dem Video): ablehnen
    const consentSel = location.hostname.indexOf('consent.') === 0
      ? 'button, input[type=submit]'
      : 'ytd-consent-bump-v2-lightbox button, tp-yt-paper-dialog button, form[action*="consent"] button';
    const rej = Array.from(document.querySelectorAll(consentSel)).find(function (x) {
      const t = (x.innerText || x.value || '') + ' ' + (x.getAttribute('aria-label') || '');
      return /alle ablehnen|reject all|ablehnen|reject/i.test(t);
    });
    if (rej) { rej.click(); return; }
    if (location.hostname.indexOf('consent.') === 0) return;
    if (location.pathname !== '/watch') {
      let t = null;
      try { t = localStorage.getItem('__lsTarget'); } catch (e) {}
      if (t && location.href !== t) { location.href = t; }
      return;
    }
    const v = document.querySelector('video');
    if (!v) return;
    v.volume = Math.max(0, Math.min(1, window.__ytVol));
    if (v.muted) v.muted = false; // YouTube startet ohne Klick sonst stumm
    const unmute = document.querySelector('.ytp-unmute');
    if (unmute && unmute.offsetParent) unmute.click();
    if (v.paused && !v.ended) v.play().catch(function () {});
    if (!v.__hooked) {
      v.__hooked = true;
      v.addEventListener('ended', function () {
        const ad = document.querySelector('.ad-showing');
        if (!ad && v.duration > 20) post({ t: 'ended' });
      });
    }
    const title = document.title.replace(/ - YouTube$/, '').replace(/^\(\d+\) /, '');
    if (title && title !== 'YouTube' && title !== sentTitle && !document.querySelector('.ad-showing')) {
      sentTitle = title; post({ t: 'playing', title: title });
    }
  }, 800);
})();
''';

  static const _html = '''<!doctype html>
<html><head><meta charset="utf-8"></head>
<body style="margin:0;background:#000">
<div id="p"></div>
<script>
let player = null, ready = false, queue = [], vol = 50;
function post(o) { try { window.chrome.webview.postMessage(o); } catch (e) {} }
function run(f) { if (ready) f(); else queue.push(f); }
function onYouTubeIframeAPIReady() {
  player = new YT.Player('p', {
    width: 320, height: 200,
    playerVars: { autoplay: 1, playsinline: 1, controls: 0, origin: location.origin },
    events: {
      onReady: () => { ready = true; player.setVolume(vol); queue.forEach(f => f()); queue = []; },
      onStateChange: e => {
        if (e.data === 0) post({ t: 'ended' });
        if (e.data === 1) { const d = player.getVideoData(); post({ t: 'playing', title: (d && d.title) || '' }); }
      },
      onError: e => post({ t: 'error', code: e.data })
    }
  });
}
window.ytPlay = (id, list, v) => run(() => {
  vol = v; player.setVolume(v);
  if (list) player.loadPlaylist({ listType: 'playlist', list: list }); else player.loadVideoById(id);
  player.unMute(); player.playVideo();
});
window.ytList = (list, v) => run(() => {
  vol = v; player.setVolume(v);
  player.loadPlaylist({ listType: 'playlist', list: list }); player.unMute(); player.playVideo();
});
window.ytStop = () => run(() => player.stopVideo());
window.ytVol = v => { vol = v; run(() => player.setVolume(v)); };
</script>
<script src="https://www.youtube.com/iframe_api"></script>
</body></html>''';
}
