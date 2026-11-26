import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../data/progress.dart';
import '../platform.dart';
import '../game/engine.dart';
import 'synth.dart';
import 'youtube.dart';

/// Musik und Soundeffekte. Alles ist fehlertolerant: Wenn Audio auf einem
/// Rechner nicht geht, läuft das Spiel einfach stumm weiter.
class Sound {
  Sound._();
  static final Sound instance = Sound._();

  static const _version = 'v1';

  late Progress _progress;
  Directory? _dir;
  final Map<String, Uint8List> _webBytes = {}; // Browser: Audio im Speicher
  bool _needsKick = false;
  final Map<String, List<AudioPlayer>> _sfx = {};
  final Map<String, int> _sfxNext = {};
  AudioPlayer? _music;
  String? _currentTrack; // 'menu', 'run' oder Pfad einer eigenen Datei
  String _wanted = 'menu';
  bool _ready = false;
  StreamSubscription<void>? _completeSub;

  /// Für das Einstellungsmenü (aktualisiert Schalter).
  final ValueNotifier<int> changed = ValueNotifier(0);

  Future<void> init(Progress progress) async {
    _progress = progress;
    try {
      if (isWeb) {
        // Im Browser gibt es kein Dateisystem: Audio direkt im Speicher erzeugen
        _webBytes['run.wav'] = makeRunTrack();
        _webBytes['menu.wav'] = makeMenuTrack();
        for (final n in kSfxNames) {
          _webBytes['$n.wav'] = makeSfx(n);
        }
      } else {
        final dir = Directory('${Directory.systemTemp.path}${Platform.pathSeparator}fi_lernspiel_audio_$_version');
        if (!dir.existsSync()) dir.createSync(recursive: true);
        _dir = dir;
        // Audiodateien im Hintergrund erzeugen (blockiert die Oberfläche nicht)
        final path = dir.path;
        await Isolate.run(() => _generateAll(path));
      }
      for (final name in kSfxNames) {
        final players = <AudioPlayer>[];
        for (var i = 0; i < (name == 'coin' ? 4 : 2); i++) {
          final p = AudioPlayer();
          await p.setReleaseMode(ReleaseMode.stop);
          await p.setSource(_source('$name.wav'));
          players.add(p);
        }
        _sfx[name] = players;
        _sfxNext[name] = 0;
      }
      _music = AudioPlayer();
      _completeSub = _music!.onPlayerComplete.listen((_) => _onTrackDone());
      _ready = true;
      await _applyMusic();
    } catch (e) {
      debugPrint('Audio nicht verfügbar: $e');
    }
  }

  static void _generateAll(String path) {
    void write(String name, Uint8List Function() make) {
      final f = File('$path${Platform.pathSeparator}$name');
      if (!f.existsSync() || f.lengthSync() < 100) f.writeAsBytesSync(make());
    }

    write('run.wav', makeRunTrack);
    write('menu.wav', makeMenuTrack);
    for (final n in kSfxNames) {
      write('$n.wav', () => makeSfx(n));
    }
  }

  String _file(String name) => '${_dir!.path}${Platform.pathSeparator}$name';

  Source _source(String name) => isWeb
      ? BytesSource(_webBytes[name]!, mimeType: 'audio/wav')
      : DeviceFileSource(_file(name));

  /// Browser erlauben Ton erst nach der ersten Eingabe: dann Musik starten.
  void userInteracted() {
    if (!_needsKick) return;
    _needsKick = false;
    _currentTrack = null;
    _applyMusic();
  }

  // ------------------------------------------------------------------ SFX

  void play(String name, {double volume = 1}) {
    if (!_ready || !_progress.sfxOn) return;
    final list = _sfx[name];
    if (list == null) return;
    final i = _sfxNext[name]!;
    _sfxNext[name] = (i + 1) % list.length;
    final p = list[i];
    final v = (_progress.sfxVolume * volume).clamp(0.0, 1.0);
    () async {
      try {
        await p.stop();
        await p.setVolume(v);
        await p.resume();
      } catch (_) {}
    }();
  }

  void game(Sfx s) => play(switch (s) {
        Sfx.coin => 'coin',
        Sfx.jump => 'jump',
        Sfx.roll => 'roll',
        Sfx.correct => 'correct',
        Sfx.wrong => 'wrong',
        Sfx.crash => 'crash',
        Sfx.powerup => 'powerup',
        Sfx.shield => 'shield',
      }, volume: s == Sfx.coin ? 0.55 : 1);

  // ---------------------------------------------------------------- Musik

  /// 'menu' oder 'run'
  Future<void> setScene(String scene) async {
    _wanted = scene;
    await _applyMusic();
  }

  Future<void> refresh() async {
    _currentTrack = null;
    await _applyMusic();
    changed.value++;
  }

  Future<void> toggleMute() async {
    await _progress.setMusicOn(!_progress.musicOn);
    await refresh();
  }

  Future<void> setMusicVolume(double v) async {
    await _progress.setMusicVolume(v);
    try {
      await _music?.setVolume(v);
    } catch (_) {}
    if (_playingYoutube) await YoutubePlayer.instance.setVolume(v);
  }

  // -------------------------------------------------------- Meine Musik

  /// Index des laufenden Titels in „Meine Musik“ (oder null).
  final ValueNotifier<int?> playingIndex = ValueNotifier(null);

  /// Kurze Statusmeldung für die Oberfläche (z. B. Fehler bei YouTube).
  final ValueNotifier<String?> status = ValueNotifier(null);

  bool _playingYoutube = false;
  int _errorsInRow = 0;

  /// Startet einen Titel aus „Meine Musik“ (Klick auf ▶).
  Future<void> playLibrary(int index) async {
    await _progress.setMusicSource('library');
    if (!_progress.musicOn) await _progress.setMusicOn(true);
    _errorsInRow = 0;
    await _startEntry(index);
    changed.value++;
  }

  /// Stoppt „Meine Musik“ und kehrt zur Spielmusik zurück.
  Future<void> stopLibrary() async {
    await _progress.setMusicSource('game');
    await _stopLibraryPlayback();
    await refresh();
  }

  Future<void> _stopLibraryPlayback() async {
    playingIndex.value = null;
    if (_playingYoutube) {
      _playingYoutube = false;
      await YoutubePlayer.instance.stop();
    }
  }

  Future<void> _startEntry(int index) async {
    final lib = _progress.library;
    final m = _music;
    if (lib.isEmpty || m == null) return;
    final i = index % lib.length;
    final e = lib[i];
    playingIndex.value = i;
    _currentTrack = 'lib:$i';
    status.value = null;
    try {
      await m.stop();
      if (e.isYoutube) {
        _playingYoutube = true;
        final yt = YoutubePlayer.instance
          ..onEnded = _next
          ..onTitle = ((t) => _setTitle(e.value, t))
          ..onError = (int code) async {
            if (code == 101 || code == 150 || code == 153) {
              // Einbetten verboten: über die normale YouTube-Seite abspielen
              final ok = await YoutubePlayer.instance.playWatchPage(e.value, _progress.musicVolume);
              if (ok) return;
            }
            status.value = '„${e.title}“ konnte nicht abgespielt werden (Fehler $code).';
            _next(error: true);
          };
        final ok = await yt.play(e.value, _progress.musicVolume);
        if (!ok) {
          status.value = 'YouTube-Player konnte nicht starten (WebView2 fehlt?).';
          _next(error: true);
        }
      } else {
        if (_playingYoutube) {
          _playingYoutube = false;
          await YoutubePlayer.instance.stop();
        }
        if (!File(e.value).existsSync()) {
          status.value = 'Datei nicht gefunden: ${e.title}';
          _next(error: true);
          return;
        }
        await m.setReleaseMode(ReleaseMode.stop);
        await m.setVolume(_progress.musicVolume);
        await m.play(DeviceFileSource(e.value));
      }
    } catch (err) {
      debugPrint('Musikfehler: $err');
    }
  }

  Future<void> _setTitle(String value, String title) async {
    final lib = _progress.library;
    var changedAny = false;
    for (final e in lib) {
      if (e.value == value && e.title != title) {
        e.title = title;
        changedAny = true;
      }
    }
    if (changedAny) {
      await _progress.setLibrary(lib);
      changed.value++;
    }
  }

  void _next({bool error = false}) {
    if (_progress.musicSource != 'library' || !_progress.musicOn) return;
    final lib = _progress.library;
    if (lib.isEmpty) return;
    if (error) {
      _errorsInRow++;
      if (_errorsInRow >= lib.length) {
        _stopLibraryPlayback();
        return;
      }
    } else {
      _errorsInRow = 0;
    }
    final i = playingIndex.value ?? -1;
    _startEntry(i + 1);
  }

  Future<void> _applyMusic() async {
    final m = _music;
    if (!_ready || m == null) return;
    try {
      if (!_progress.musicOn) {
        _currentTrack = null;
        await m.stop();
        await _stopLibraryPlayback();
        return;
      }
      if (hasFileSystem && _progress.musicSource == 'library' && _progress.library.isNotEmpty) {
        // Meine Musik läuft durch, egal ob Menü oder Spiel.
        if (playingIndex.value != null) return;
        await _startEntry(0);
        return;
      }
      await _stopLibraryPlayback();
      if (_currentTrack == _wanted) return;
      _currentTrack = _wanted;
      await m.stop();
      await m.setReleaseMode(ReleaseMode.loop);
      await m.setVolume(_progress.musicVolume);
      await m.play(_source('$_wanted.wav'));
    } catch (e) {
      debugPrint('Musikfehler: $e');
      if (isWeb) _needsKick = true;
    }
  }

  void _onTrackDone() {
    if (_progress.musicSource == 'library' && !_playingYoutube) _next();
  }

  void dispose() {
    _completeSub?.cancel();
    YoutubePlayer.instance.dispose();
  }
}
