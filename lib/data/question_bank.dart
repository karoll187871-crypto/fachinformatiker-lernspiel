import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart' show rootBundle;

import 'progress.dart';

/// Eine Prüfungsfrage mit genau einer richtigen Antwort.
class Question {
  Question({
    required this.pruefung,
    required this.thema,
    required this.frage,
    required this.richtig,
    required this.falsch,
    required this.erklaerung,
    this.source = 'spiel',
    this.bereich = '',
    String? key,
  }) : _key = key;

  factory Question.fromJson(Map<String, dynamic> j) => Question(
        pruefung: j['pruefung'] as String,
        thema: j['thema'] as String,
        frage: j['frage'] as String,
        richtig: j['richtig'] as String,
        falsch: (j['falsch'] as List<dynamic>).cast<String>(),
        erklaerung: (j['erklaerung'] as String?) ?? '',
      );

  final String pruefung; // "AP1" oder "AP2"
  final String thema;
  final String frage;
  final String richtig;
  final List<String> falsch;
  final String erklaerung;

  /// 'spiel' (eingebaut), 'eigene' (importiert) oder 'cwillam' (Lernkarte)
  final String source;

  /// Bei Lernkarten: 'AP1', 'AP2 FIAE' oder 'AP2 FISI'
  final String bereich;
  final String? _key;

  /// Stabiler Schlüssel für die Statistik.
  String get id => _key ?? frage;

  bool get isCard => source == 'cwillam';
}

/// Lernkarte aus den cwillam-Trackern (AGPL-3.0, github.com/cwillam).
class Flashcard {
  Flashcard(this.id, this.pruefung, this.bereich, this.thema, this.frage, this.antwort);
  final String id;
  final String pruefung;
  final String bereich; // 'AP1', 'AP2 FIAE', 'AP2 FISI'
  final String thema;
  final String frage;
  final String antwort;
}

class QuestionBank {
  QuestionBank(this.builtIn,
      [List<Question> custom = const [], this.cards = const [], this.cardQuestions = const []])
      : custom = List.of(custom);

  final List<Question> builtIn;
  List<Question> custom;

  /// Alle Lernkarten (für den Lernkarten-Modus).
  final List<Flashcard> cards;

  /// Lernkarten, die als 3-Antworten-Frage ins Rennen passen.
  final List<Question> cardQuestions;

  /// Lernkarten im Lauf mitmischen?
  bool includeCards = true;

  /// AP2-Fachrichtung für Lernkarten: 'beide', 'FIAE' oder 'FISI'
  String ap2Track = 'beide';

  bool _trackOk(String bereich) =>
      ap2Track == 'beide' || !bereich.startsWith('AP2') || bereich.endsWith(ap2Track);

  List<Question> get all => [
        ...builtIn,
        ...custom,
        if (includeCards) ...cardQuestions.where((q) => _trackOk(q.bereich)),
      ];

  List<Flashcard> cardsFor(String? exam) => cards
      .where((c) => (exam == null || c.pruefung == exam) && _trackOk(c.bereich))
      .toList();

  static Future<QuestionBank> load({String? customJson}) async {
    final raw = await rootBundle.loadString('assets/questions/fragen.json');
    final custom = customJson == null ? <Question>[] : (tryParse(customJson) ?? []);
    var cards = <Flashcard>[];
    var cardQs = <Question>[];
    try {
      final rawCards = await rootBundle.loadString('assets/questions/lernkarten.json');
      (cards, cardQs) = parseCards(rawCards);
    } catch (_) {
      // Ohne Lernkarten weiterspielen
    }
    return QuestionBank(parse(raw), custom, cards, cardQs);
  }

  /// Liest lernkarten.json. Karten mit Feld 'f' (zwei Indizes passender
  /// falscher Antworten aus demselben Thema) werden zu Lauf-Fragen.
  static (List<Flashcard>, List<Question>) parseCards(String raw) {
    final list = (jsonDecode(raw) as List<dynamic>).cast<Map<String, dynamic>>();
    final cards = [
      for (final j in list)
        Flashcard(j['id'] as String, j['pruefung'] as String, j['bereich'] as String,
            j['thema'] as String, j['frage'] as String, j['antwort'] as String),
    ];
    final qs = <Question>[];
    for (var i = 0; i < list.length; i++) {
      final f = list[i]['f'];
      if (f is! List || f.length < 2) continue;
      final c = cards[i];
      qs.add(Question(
        pruefung: c.pruefung,
        thema: c.thema,
        frage: c.frage,
        richtig: c.antwort,
        falsch: [for (final k in f) cards[k as int].antwort],
        erklaerung: 'Lernkarte ${c.bereich} · ${c.thema} (Quelle: cwillam-Tracker, AGPL-3.0)',
        source: 'cwillam',
        bereich: c.bereich,
        key: c.id,
      ));
    }
    return (cards, qs);
  }

  static List<Question> parse(String raw) {
    final list = jsonDecode(raw) as List<dynamic>;
    return list.map((e) => Question.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// Prüft importierte Fragen. Gibt null zurück, wenn das Format nicht passt.
  /// Ungültige Einträge werden übersprungen.
  static List<Question>? tryParse(String raw) {
    try {
      final list = jsonDecode(raw);
      if (list is! List) return null;
      final out = <Question>[];
      for (final e in list) {
        if (e is! Map<String, dynamic>) continue;
        try {
          final q = Question.fromJson(e);
          if (q.frage.trim().isEmpty || q.richtig.trim().isEmpty) continue;
          if (q.falsch.length < 2) continue;
          if (q.pruefung != 'AP1' && q.pruefung != 'AP2') continue;
          out.add(q);
        } catch (_) {
          // Eintrag überspringen
        }
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  List<Question> forExam(String? exam) =>
      exam == null ? all : all.where((q) => q.pruefung == exam).toList();

  List<String> topics(String? exam) {
    final result = <String>[];
    for (final q in forExam(exam)) {
      if (!result.contains(q.thema)) result.add(q.thema);
    }
    return result;
  }
}

/// Zieht Fragen gemischt, schwache Fragen kommen öfter dran,
/// falsch beantwortete kommen nach kurzer Zeit wieder.
class QuestionDeck {
  QuestionDeck(List<Question> all, this.progress, this._rng)
      : pool = _withoutLearned(all, progress) {
    _refill();
  }

  final List<Question> pool;
  final Progress progress;
  final Random _rng;
  final List<Question> _queue = [];
  Question? _last;

  /// Im Abschlusstest gelernte Fragen kommen im Lauf nicht mehr dran.
  static List<Question> _withoutLearned(List<Question> all, Progress p) {
    final open = all.where((q) => !p.isLearned(q)).toList();
    return open.length >= 3 ? open : all;
  }

  /// Reihenfolge: vor allem neue Fragen (mehr Abwechslung). Fragen, die
  /// früher falsch waren, werden regelmäßig eingestreut. Schon richtig
  /// beantwortete Fragen kommen erst ganz am Ende.
  void _refill() {
    final fresh = <Question>[], weak = <Question>[], known = <Question>[];
    for (final q in pool) {
      final (c, w) = progress.statOf(q);
      if (c == 0 && w == 0) {
        fresh.add(q);
      } else if (w >= c) {
        weak.add(q);
      } else {
        known.add(q);
      }
    }
    fresh.shuffle(_rng);
    weak.shuffle(_rng);
    known.shuffle(_rng);
    final mixed = <Question>[];
    var wi = 0;
    for (var i = 0; i < fresh.length; i++) {
      if (i % 4 == 3 && wi < weak.length) mixed.add(weak[wi++]);
      mixed.add(fresh[i]);
    }
    mixed.addAll(weak.skip(wi));
    mixed.addAll(known);
    _queue.addAll(mixed);
    if (_queue.length > 1 && _queue.first == _last) {
      _queue.add(_queue.removeAt(0));
    }
  }

  Question next() {
    if (_queue.isEmpty) _refill();
    final q = _queue.removeAt(0);
    _last = q;
    return q;
  }

  /// Falsch beantwortete Frage kommt nach genau 2 anderen Fragen erneut –
  /// so lange, bis sie richtig beantwortet wurde.
  void requeue(Question q) {
    _queue.remove(q);
    _queue.insert(min(2, _queue.length), q);
  }
}
