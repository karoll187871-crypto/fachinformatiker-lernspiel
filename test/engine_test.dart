import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:fachinformatiker_lernspiel/data/progress.dart';
import 'package:fachinformatiker_lernspiel/audio/youtube.dart';
import 'package:fachinformatiker_lernspiel/data/question_bank.dart';
import 'package:fachinformatiker_lernspiel/game/engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

List<Question> _loadQuestions() {
  final raw = File('assets/questions/fragen.json').readAsStringSync();
  return (jsonDecode(raw) as List<dynamic>)
      .map((e) => Question.fromJson(e as Map<String, dynamic>))
      .toList();
}

void main() {
  test('Fragenkatalog ist gültig', () {
    final qs = _loadQuestions();
    expect(qs.length, greaterThan(150));
    final seen = <String>{};
    for (final q in qs) {
      expect(seen.add(q.frage), isTrue, reason: 'doppelt: ${q.frage}');
      expect(['AP1', 'AP2'], contains(q.pruefung));
      expect(q.falsch.length, greaterThanOrEqualTo(2), reason: q.frage);
      expect(q.falsch, isNot(contains(q.richtig)), reason: q.frage);
      expect(q.erklaerung, isNotEmpty, reason: q.frage);
    }
  });

  test('Lernkarten werden korrekt geladen', () {
    final raw = File('assets/questions/lernkarten.json').readAsStringSync();
    final (cards, qs) = QuestionBank.parseCards(raw);
    expect(cards.length, greaterThan(2500));
    expect(qs.length, greaterThan(2000));
    for (final q in qs) {
      expect(q.falsch.length, 2, reason: q.frage);
      expect(q.falsch, isNot(contains(q.richtig)), reason: q.frage);
      expect(q.isCard, isTrue);
    }
    expect(cards.map((c) => c.id).toSet().length, cards.length, reason: 'IDs eindeutig');
  });

  test('Springen landet wieder, Rollen endet von selbst', () {
    final g = RunnerGame(demo: true, seed: 1);
    g.jump();
    expect(g.airborne, isTrue);
    for (var i = 0; i < 120; i++) {
      g.update(1 / 60);
    }
    expect(g.airborne, isFalse);
    g.roll();
    expect(g.rolling, isTrue);
    for (var i = 0; i < 60; i++) {
      g.update(1 / 60);
    }
    expect(g.rolling, isFalse, reason: 'Ducken muss automatisch enden');
  });

  test('Spurwechsel bleibt in 3 Spuren', () {
    final g = RunnerGame(demo: true, seed: 1);
    g.moveLeft();
    g.moveLeft();
    expect(g.lane, -1);
    g.moveRight();
    g.moveRight();
    g.moveRight();
    expect(g.lane, 1);
  });

  test('Tor wertet die gewählte Spur aus', () async {
    SharedPreferences.setMockInitialValues({});
    final progress = await Progress.load();
    final qs = _loadQuestions();
    final g = RunnerGame(
      deck: QuestionDeck(qs, progress, Random(1)),
      seed: 2,
    );
    g.lives = 99;
    g.invuln = 1e9; // Hindernisse ignorieren, nur Tor testen
    Gate? gate;
    for (var i = 0; i < 60 * 60 && g.correctCount == 0; i++) {
      g.update(1 / 60);
      gate ??= g.activeGate;
      if (gate != null) {
        g.lane = gate.correctIndex - 1;
      }
      if (g.phase == Phase.explaining) g.continueAfterExplanation();
      g.invuln = 1e9;
    }
    expect(gate, isNotNull);
    expect(g.correctCount, 1);
    expect(g.wrongCount, 0);
  });

  test('Deck: neue Fragen zuerst, falsche nach genau 2 Fragen, Gelerntes raus', () async {
    SharedPreferences.setMockInitialValues({});
    final progress = await Progress.load();
    final qs = _loadQuestions().take(20).toList();
    await progress.record(qs[0], correct: true); // schon bekannt
    await progress.markLearned(qs[1]); // gelernt -> nicht mehr im Lauf
    final deck = QuestionDeck(qs, progress, Random(1));
    expect(deck.pool.contains(qs[1]), isFalse);
    final first = deck.next();
    expect(first, isNot(qs[0]), reason: 'bekannte Frage kommt nicht zuerst');
    deck.requeue(first);
    deck.next();
    deck.next();
    expect(deck.next(), first, reason: 'falsche Frage kommt nach 2 anderen wieder');
  });

  test('YouTube-Links werden erkannt', () {
    expect(YoutubePlayer.parse('https://www.youtube.com/watch?v=dQw4w9WgXcQ')?.video, 'dQw4w9WgXcQ');
    expect(YoutubePlayer.parse('https://youtu.be/dQw4w9WgXcQ?si=abc')?.video, 'dQw4w9WgXcQ');
    expect(YoutubePlayer.parse('https://music.youtube.com/watch?v=dQw4w9WgXcQ&list=RDAMVM')?.video, 'dQw4w9WgXcQ');
    expect(YoutubePlayer.parse('https://www.youtube.com/shorts/abcdEFGH123')?.video, 'abcdEFGH123');
    expect(YoutubePlayer.parse('http://youtube.com/watch?v=dQw4w9WgXcQ'), isNull);
    expect(YoutubePlayer.parse('https://evil.example/watch?v=dQw4w9WgXcQ'), isNull);
  });

  test('Zeitlupe bei Fragen, Leertaste beendet sie und sperrt die Spur', () async {
    SharedPreferences.setMockInitialValues({});
    final progress = await Progress.load();
    final g = RunnerGame(
        deck: QuestionDeck(_loadQuestions(), progress, Random(2)),
        slowmo: 0.3,
        seed: 2,
        tempo: Tempo.entspannt);
    g.phase = Phase.running;
    for (var i = 0; i < 60 * 30 && g.activeGate == null; i++) {
      g.update(1 / 60);
      g.invuln = 1e9;
    }
    expect(g.slowmoActive, isTrue);
    for (var i = 0; i < 60; i++) {
      g.update(1 / 60);
      g.invuln = 1e9;
    }
    expect(g.timeScale, lessThan(0.4));
    final lane = g.lane;
    expect(g.confirmAnswer(), isTrue);
    g.moveLeft();
    g.moveRight();
    expect(g.lane, lane);
    for (var i = 0; i < 60; i++) {
      g.update(1 / 60);
      g.invuln = 1e9;
    }
    expect(g.timeScale, greaterThan(0.9));
  });

  test('Cloud-Spielstand: Export/Import behält Typen, Gerätedaten bleiben lokal', () async {
    SharedPreferences.setMockInitialValues({});
    final a = await Progress.load();
    await a.addCoins(1234);
    await a.setMusicVolume(0.3);
    await a.unlockSkin('cloud');
    await a.setSlowmo(0.3);
    final qs = _loadQuestions();
    await a.record(qs[0], correct: false);
    await a.markLearned(qs[1]);
    final snap = jsonDecode(jsonEncode(a.exportSnapshot())) as Map<String, dynamic>;
    expect(snap.containsKey('music_vol'), isFalse, reason: 'Lautstärke bleibt auf dem Gerät');

    SharedPreferences.setMockInitialValues({'music_vol': 0.9});
    final b = await Progress.load();
    await b.importSnapshot(snap);
    expect(b.totalCoins, 1234);
    expect(b.slowmo, 0.3);
    expect(b.ownedSkins.contains('cloud'), isTrue);
    expect(b.statOf(qs[0]), (0, 1));
    expect(b.isLearned(qs[1]), isTrue);
    expect(b.musicVolume, 0.9);
  });
}
