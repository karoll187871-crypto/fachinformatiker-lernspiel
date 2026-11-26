import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'cosmetics.dart';
import 'question_bank.dart';
import 'quests.dart';

/// Speichert Highscores, Einstellungen, Lernstatistik, XP,
/// gekaufte Skins und Quests lokal.
/// Ein Eintrag in „Meine Musik“.
class MusicEntry {
  MusicEntry(this.type, this.value, this.title);
  final String type; // 'file' oder 'yt'
  final String value; // Dateipfad oder Link
  String title;

  bool get isYoutube => type == 'yt';

  Map<String, dynamic> toJson() => {'type': type, 'value': value, 'title': title};
  static MusicEntry fromJson(Map<String, dynamic> j) =>
      MusicEntry(j['type'] as String, j['value'] as String, (j['title'] as String?) ?? '');
}

class Progress {
  Progress._(this._prefs, this._stats);

  final SharedPreferences _prefs;
  final Map<String, List<int>> _stats; // id -> [richtig, falsch]
  List<Quest> _quests = [];

  static Future<Progress> load() async {
    final prefs = await SharedPreferences.getInstance();
    final map = <String, List<int>>{};
    final raw = prefs.getString('stats_v2');
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        decoded.forEach((key, value) {
          final l = (value as List<dynamic>).cast<int>();
          if (l.length == 2) map[key] = [l[0], l[1]];
        });
      } catch (_) {
        // Kaputte Daten ignorieren, Statistik startet neu.
      }
    }
    final p = Progress._(prefs, map);
    p._loadQuests();
    return p;
  }

  // ------------------------------------------------------ Cloud-Spielstand

  /// Nur auf diesem Gerät gültig (Pfade, Grafik, Lautstärke, Anmeldung).
  static const _localOnly = {
    'quality', 'show_fps', 'library_v1', 'own_music', 'yt_links', 'sky_custom_path',
    'music_src', 'music_vol', 'sfx_vol', 'music_on', 'sfx_on',
  };

  static bool _syncable(String k) => !k.startsWith('acct_') && !_localOnly.contains(k);

  /// Spielstand als JSON (mit Typangabe, damit int/double erhalten bleiben).
  Map<String, dynamic> exportSnapshot() {
    final out = <String, dynamic>{};
    for (final k in _prefs.getKeys()) {
      if (!_syncable(k)) continue;
      final v = _prefs.get(k);
      if (v is bool) {
        out[k] = {'t': 'b', 'v': v};
      } else if (v is int) {
        out[k] = {'t': 'i', 'v': v};
      } else if (v is double) {
        out[k] = {'t': 'd', 'v': v};
      } else if (v is String) {
        out[k] = {'t': 's', 'v': v};
      } else if (v is List) {
        out[k] = {'t': 'l', 'v': v.cast<String>()};
      }
    }
    return out;
  }

  /// Spielstand aus der Cloud übernehmen (ersetzt den Stand auf diesem Gerät).
  Future<void> importSnapshot(Map<String, dynamic> data) async {
    for (final k in _prefs.getKeys().toList()) {
      if (_syncable(k) && !data.containsKey(k)) await _prefs.remove(k);
    }
    for (final e in data.entries) {
      if (!_syncable(e.key) || e.value is! Map) continue;
      final m = e.value as Map;
      final v = m['v'];
      switch (m['t']) {
        case 'b':
          await _prefs.setBool(e.key, v as bool);
        case 'i':
          await _prefs.setInt(e.key, (v as num).toInt());
        case 'd':
          await _prefs.setDouble(e.key, (v as num).toDouble());
        case 's':
          await _prefs.setString(e.key, v as String);
        case 'l':
          await _prefs.setStringList(e.key, (v as List).cast<String>());
      }
    }
    _reloadCaches();
  }

  void _reloadCaches() {
    _stats.clear();
    final raw = _prefs.getString('stats_v2');
    if (raw != null) {
      try {
        (jsonDecode(raw) as Map<String, dynamic>).forEach((key, value) {
          final l = (value as List<dynamic>).cast<int>();
          if (l.length == 2) _stats[key] = [l[0], l[1]];
        });
      } catch (_) {}
    }
    _learned
      ..clear()
      ..addAll(_prefs.getStringList('learned_v1') ?? const []);
    _srs = null;
    _quests = [];
    _loadQuests();
  }

  // ---------------------------------------------------------- Lernstatistik

  (int, int) statOf(Question q) {
    final s = _stats[q.id];
    return s == null ? (0, 0) : (s[0], s[1]);
  }

  bool isMastered(Question q) {
    final (c, w) = statOf(q);
    return c >= 2 && c > w;
  }

  int masteredCount(Iterable<Question> qs) => qs.where(isMastered).length;

  Future<void> record(Question q, {required bool correct}) async {
    final s = _stats.putIfAbsent(q.id, () => [0, 0]);
    if (correct) {
      s[0]++;
    } else {
      s[1]++;
    }
    await _prefs.setString('stats_v2', jsonEncode(_stats));
  }

  Future<void> resetStats() async {
    _stats.clear();
    _learned.clear();
    await _prefs.remove('stats_v2');
    await _prefs.remove('learned_v1');
  }

  // Im Abschlusstest gelernte Fragen
  late final Set<String> _learned = {...?_prefs.getStringList('learned_v1')};

  bool isLearned(Question q) => _learned.contains(q.id);

  Future<void> markLearned(Question q) async {
    if (_learned.add(q.id)) {
      await _prefs.setStringList('learned_v1', _learned.toList());
    }
  }

  int get learnedCount => _learned.length;

  int highscore(String mode) => _prefs.getInt('hs_$mode') ?? 0;

  /// Gibt true zurück, wenn ein neuer Rekord erreicht wurde.
  Future<bool> submitScore(String mode, int score) async {
    if (score > highscore(mode)) {
      await _prefs.setInt('hs_$mode', score);
      return true;
    }
    return false;
  }

  // ------------------------------------------------------------- Münzen/XP

  int get totalCoins => _prefs.getInt('coins') ?? 0;
  Future<void> addCoins(int c) => _prefs.setInt('coins', totalCoins + c);

  bool canAfford(int price) => totalCoins >= price;
  Future<bool> spendCoins(int price) async {
    if (!canAfford(price)) return false;
    await _prefs.setInt('coins', totalCoins - price);
    return true;
  }

  int get xp => _prefs.getInt('xp') ?? 0;
  int get level => levelForXp(xp);

  /// Gibt die Anzahl gewonnener Level zurück.
  Future<int> addXp(int amount) async {
    final before = level;
    await _prefs.setInt('xp', xp + amount);
    return level - before;
  }

  // --------------------------------------------------------- Skins & Spuren

  Set<String> get ownedSkins =>
      {'azubi', ...(_prefs.getStringList('skins_owned') ?? const [])};
  Set<String> get ownedTrails =>
      {'none', ...(_prefs.getStringList('trails_owned') ?? const [])};

  String get skinId => _prefs.getString('skin') ?? 'azubi';
  String get trailId => _prefs.getString('trail') ?? 'none';
  Skin get skin => skinById(skinId);
  Trail get trail => trailById(trailId);

  Future<void> selectSkin(String id) => _prefs.setString('skin', id);
  Future<void> selectTrail(String id) => _prefs.setString('trail', id);

  Future<void> unlockSkin(String id) =>
      _prefs.setStringList('skins_owned', {...ownedSkins, id}.toList());
  Future<void> unlockTrail(String id) =>
      _prefs.setStringList('trails_owned', {...ownedTrails, id}.toList());

  Set<String> get ownedSkies => {'sunset', ...(_prefs.getStringList('skies_owned') ?? const [])};
  String get skyId => _prefs.getString('sky') ?? 'sunset';
  Future<void> selectSky(String id) => _prefs.setString('sky', id);
  Future<void> unlockSky(String id) =>
      _prefs.setStringList('skies_owned', {...ownedSkies, id}.toList());

  /// Pfad zur Kopie des eigenen Himmelsbilds (im App-Datenordner).
  String? get customSkyPath => _prefs.getString('sky_custom_path');
  Future<void> setCustomSkyPath(String path) => _prefs.setString('sky_custom_path', path);

  // ----------------------------------------------------------------- Quests

  List<Quest> get quests => _quests;

  String _today() {
    final n = DateTime.now();
    return '${n.year}-${n.month}-${n.day}';
  }

  void _loadQuests() {
    final raw = _prefs.getString('quests');
    if (raw == null || _prefs.getString('quests_day') != _today()) return;
    try {
      _quests = (jsonDecode(raw) as List<dynamic>)
          .map((e) => Quest.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      _quests = [];
    }
  }

  /// Erzeugt neue Tagesquests, wenn ein neuer Tag begonnen hat.
  Future<void> ensureQuests(List<String> topics) async {
    if (_quests.isNotEmpty && _prefs.getString('quests_day') == _today()) return;
    _quests = generateQuests(Random(), topics);
    await _saveQuests();
  }

  Future<void> _saveQuests() async {
    await _prefs.setString('quests_day', _today());
    await _prefs.setString('quests', jsonEncode(_quests.map((q) => q.toJson()).toList()));
  }

  /// Überträgt den Lauf auf die Quests. Gibt neu erledigte Quests zurück.
  Future<List<Quest>> applyRun(RunStats s) async {
    final finished = <Quest>[];
    for (final q in _quests) {
      if (q.apply(s)) finished.add(q);
    }
    await _saveQuests();
    return finished;
  }

  Future<bool> claimQuest(Quest q) async {
    if (!q.done || q.claimed) return false;
    q.claimed = true;
    await addCoins(q.reward);
    await addXp(q.xp);
    await _saveQuests();
    return true;
  }

  // ----------------------------------------------------------- Einstellungen

  String get tempo => _prefs.getString('tempo') ?? 'normal';
  Future<void> setTempo(String t) => _prefs.setString('tempo', t);

  bool get musicOn => _prefs.getBool('music_on') ?? true;
  Future<void> setMusicOn(bool v) => _prefs.setBool('music_on', v);

  bool get sfxOn => _prefs.getBool('sfx_on') ?? true;
  Future<void> setSfxOn(bool v) => _prefs.setBool('sfx_on', v);

  double get musicVolume => _prefs.getDouble('music_vol') ?? 0.55;
  Future<void> setMusicVolume(double v) => _prefs.setDouble('music_vol', v);

  double get sfxVolume => _prefs.getDouble('sfx_vol') ?? 0.7;
  Future<void> setSfxVolume(double v) => _prefs.setDouble('sfx_vol', v);

  /// 'game' = Spielmusik, 'library' = Meine Musik (Dateien + YouTube)
  String get musicSource {
    final v = _prefs.getString('music_src') ?? 'game';
    return v == 'game' ? 'game' : 'library';
  }
  Future<void> setMusicSource(String v) => _prefs.setString('music_src', v);

  /// Musik-Bibliothek: eigene Dateien und YouTube-Links.
  List<MusicEntry> get library {
    final raw = _prefs.getString('library_v1');
    if (raw != null) {
      try {
        return (jsonDecode(raw) as List<dynamic>)
            .map((e) => MusicEntry.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {}
    }
    // Übernahme aus der alten Version
    return [
      for (final f in _prefs.getStringList('own_music') ?? const <String>[])
        MusicEntry('file', f, f.split(RegExp(r'[\/]')).last),
      for (final l in _prefs.getStringList('yt_links') ?? const <String>[]) MusicEntry('yt', l, l),
    ];
  }

  Future<void> setLibrary(List<MusicEntry> v) =>
      _prefs.setString('library_v1', jsonEncode(v.map((e) => e.toJson()).toList()));

  /// 'auto', 'high', 'mid', 'low'
  String get quality => _prefs.getString('quality') ?? 'auto';
  Future<void> setQuality(String v) => _prefs.setString('quality', v);

  /// Zeitlupe bei Fragen: 1.0 = aus, sonst Spieltempo-Faktor.
  double get slowmo => _prefs.getDouble('slowmo') ?? 0.5;
  Future<void> setSlowmo(double v) => _prefs.setDouble('slowmo', v);

  bool get showFps => _prefs.getBool('show_fps') ?? false;
  Future<void> setShowFps(bool v) => _prefs.setBool('show_fps', v);

  // ------------------------------------------------------------ Lernkarten

  bool get includeCards => _prefs.getBool('cards_in_run') ?? true;
  Future<void> setIncludeCards(bool v) => _prefs.setBool('cards_in_run', v);

  String get ap2Track => _prefs.getString('ap2_track') ?? 'beide';
  Future<void> setAp2Track(String v) => _prefs.setString('ap2_track', v);

  Map<String, List<int>>? _srs;

  /// Leitner-Fach (0–6) und Fälligkeitstag je Karte.
  Map<String, List<int>> get _cardSrs {
    if (_srs != null) return _srs!;
    final m = <String, List<int>>{};
    final raw = _prefs.getString('cards_srs');
    if (raw != null) {
      try {
        (jsonDecode(raw) as Map<String, dynamic>).forEach((k, v) {
          final l = (v as List<dynamic>).cast<int>();
          if (l.length == 2) m[k] = l;
        });
      } catch (_) {}
    }
    return _srs = m;
  }

  static int today() => DateTime.now().millisecondsSinceEpoch ~/ 86400000;

  /// null = neue Karte
  int? cardBox(String id) => _cardSrs[id]?[0];
  bool cardDue(String id) => (_cardSrs[id]?[1] ?? 0) <= today();

  static const _intervals = [0, 1, 2, 4, 8, 16, 32];

  /// rating: 0 = nicht gewusst, 1 = geraten, 2 = nachgedacht, 3 = sofort gewusst
  Future<void> rateCard(String id, int rating) async {
    final box = cardBox(id) ?? 0;
    final next = switch (rating) {
      0 => 0,
      1 => box,
      2 => box + 1,
      _ => box + 2,
    }.clamp(0, 6);
    _cardSrs[id] = [next, today() + (rating == 0 ? 0 : _intervals[next])];
    await _prefs.setString('cards_srs', jsonEncode(_cardSrs));
  }

  int cardsLearned(Iterable<String> ids) => ids.where((i) => (cardBox(i) ?? 0) >= 3).length;

  // ---------------------------------------------------------- Eigene Fragen

  String? get customQuestionsJson => _prefs.getString('custom_questions');
  Future<void> setCustomQuestionsJson(String? v) => v == null
      ? _prefs.remove('custom_questions')
      : _prefs.setString('custom_questions', v);
}
