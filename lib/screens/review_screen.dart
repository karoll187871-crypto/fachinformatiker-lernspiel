import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../audio/sound.dart';
import '../data/progress.dart';
import '../data/question_bank.dart';
import '../ui.dart';

/// Ergebnis des Abschlusstests.
enum ReviewExit { nextRound, menu, back }

/// Abschlusstest nach der Runde (Duolingo-Stil): Alle Fragen, die im Lauf
/// falsch waren, werden nochmal abgefragt. Richtig = gelernt, die Frage
/// kommt im Lauf nicht mehr dran (Lernkarten/Katalog zeigen sie weiter).
class ReviewScreen extends StatefulWidget {
  const ReviewScreen({super.key, required this.questions, required this.progress});
  final List<Question> questions;
  final Progress progress;

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  final _rng = Random();
  int _index = 0;
  int? _chosen;
  int _learned = 0;
  late List<String> _options;
  late int _correct;

  Question? get _q => _index < widget.questions.length ? widget.questions[_index] : null;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    _prepare();
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  void _prepare() {
    final q = _q;
    if (q == null) return;
    final wrong = [...q.falsch]..shuffle(_rng);
    _options = [q.richtig, ...wrong.take(2)]..shuffle(_rng);
    _correct = _options.indexOf(q.richtig);
    _chosen = null;
  }

  Future<void> _pick(int i) async {
    if (_chosen != null || _q == null) return;
    setState(() => _chosen = i);
    final ok = i == _correct;
    Sound.instance.play(ok ? 'correct' : 'wrong');
    await widget.progress.record(_q!, correct: ok);
    if (ok) {
      _learned++;
      await widget.progress.markLearned(_q!);
    }
  }

  void _next() {
    if (_chosen == null) return;
    setState(() {
      _index++;
      _prepare();
    });
    if (_q == null && _learned > 0) {
      widget.progress.addXp(_learned * 10);
      Sound.instance.play('levelup');
    }
  }

  bool _onKey(KeyEvent e) {
    if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? false)) return false;
    if (e is! KeyDownEvent) return false;
    final k = e.logicalKey;
    final keys = [
      [LogicalKeyboardKey.digit1, LogicalKeyboardKey.keyA, LogicalKeyboardKey.numpad1],
      [LogicalKeyboardKey.digit2, LogicalKeyboardKey.keyB, LogicalKeyboardKey.numpad2],
      [LogicalKeyboardKey.digit3, LogicalKeyboardKey.keyC, LogicalKeyboardKey.numpad3],
    ];
    for (var i = 0; i < 3; i++) {
      if (keys[i].contains(k) && _q != null) {
        _pick(i);
        return true;
      }
    }
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.numpadEnter) {
      if (_q == null) {
        Navigator.of(context).pop(ReviewExit.nextRound);
      } else {
        _next();
      }
      return true;
    }
    if (k == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop(_q == null ? ReviewExit.menu : ReviewExit.back);
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.questions.length;
    return Scaffold(
      backgroundColor: const Color(0xFF0D1020),
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 24, 0),
            child: Row(children: [
              IconButton(
                tooltip: 'Schließen (Esc)',
                icon: const Icon(Icons.close),
                onPressed: () =>
                    Navigator.of(context).pop(_q == null ? ReviewExit.menu : ReviewExit.back),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(end: total == 0 ? 1 : _index / total),
                    duration: const Duration(milliseconds: 300),
                    builder: (_, v, __) => LinearProgressIndicator(
                      value: v,
                      minHeight: 14,
                      color: kGood,
                      backgroundColor: Colors.white12,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text('${min(_index + 1, total)}/$total',
                  style: const TextStyle(fontWeight: FontWeight.w800, color: Colors.white70)),
            ]),
          ),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: _q == null ? _summary(total) : _question(_q!),
                ),
              ),
            ),
          ),
          if (_q != null && _chosen != null) _feedbackBar(),
        ]),
      ),
    );
  }

  Widget _question(Question q) {
    const letters = ['A', 'B', 'C'];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('ABSCHLUSSTEST', style: TextStyle(color: kAccent, fontWeight: FontWeight.w800, letterSpacing: 3)),
      const SizedBox(height: 6),
      Text(q.isCard ? 'Lernkarte ${q.bereich} · ${q.thema}' : '${q.pruefung} · ${q.thema}',
          style: const TextStyle(color: Colors.white54)),
      const SizedBox(height: 12),
      Text(q.frage, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900)),
      const SizedBox(height: 22),
      for (var i = 0; i < _options.length; i++) ...[
        _option(i, letters[i], _options[i]),
        const SizedBox(height: 12),
      ],
    ]);
  }

  Widget _option(int i, String letter, String text) {
    final answered = _chosen != null;
    Color border = Colors.white24, fill = Colors.white.withValues(alpha: 0.04);
    if (answered && i == _correct) {
      border = kGood;
      fill = kGood.withValues(alpha: 0.18);
    } else if (answered && i == _chosen) {
      border = kBad;
      fill = kBad.withValues(alpha: 0.18);
    }
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: answered ? null : () => _pick(i),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: border, width: 2),
          boxShadow: [BoxShadow(color: border.withValues(alpha: 0.6), offset: const Offset(0, 4))],
        ),
        child: Row(children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: Colors.white30),
            ),
            child: Text(letter, style: const TextStyle(fontWeight: FontWeight.w900)),
          ),
          const SizedBox(width: 14),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
          Text('${i + 1}', style: const TextStyle(color: Colors.white30)),
        ]),
      ),
    );
  }

  Widget _feedbackBar() {
    final ok = _chosen == _correct;
    final q = _q!;
    final c = ok ? kGood : kBad;
    return Container(
      width: double.infinity,
      color: c.withValues(alpha: 0.16),
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Row(children: [
            Icon(ok ? Icons.check_circle : Icons.cancel, color: c, size: 44),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(ok ? 'Richtig – gelernt!' : 'Noch nicht ganz.',
                    style: TextStyle(color: c, fontSize: 22, fontWeight: FontWeight.w900)),
                const SizedBox(height: 2),
                Text(
                    ok
                        ? 'Diese Frage kommt im Lauf nicht mehr dran.'
                        : 'Richtig ist: ${q.richtig}${q.erklaerung.isNotEmpty && !q.isCard ? '\n${q.erklaerung}' : ''}',
                    style: const TextStyle(fontSize: 15)),
              ]),
            ),
            const SizedBox(width: 14),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: c,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 16),
              ),
              onPressed: _next,
              child: const Text('WEITER', style: TextStyle(fontWeight: FontWeight.w900)),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _summary(int total) {
    return Panel(
      padding: const EdgeInsets.all(30),
      child: Column(children: [
        Icon(_learned == total ? Icons.emoji_events : Icons.school, color: kGold, size: 70),
        const SizedBox(height: 10),
        Text('$_learned von $total gelernt',
            style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w900)),
        const SizedBox(height: 6),
        Text(
            _learned == total
                ? 'Alles sitzt! Diese Fragen kommen im Lauf nicht mehr.'
                : 'Die übrigen Fragen kommen in den nächsten Runden wieder.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70)),
        if (_learned > 0) ...[
          const SizedBox(height: 6),
          Text('+${_learned * 10} XP', style: const TextStyle(color: Color(0xFFB388FF), fontWeight: FontWeight.w800)),
        ],
        const SizedBox(height: 22),
        Wrap(spacing: 12, runSpacing: 10, alignment: WrapAlignment.center, children: [
          BigButton(
            label: 'Hauptmenü',
            hint: 'Esc',
            icon: Icons.home_rounded,
            color: Colors.white70,
            onPressed: () => Navigator.of(context).pop(ReviewExit.menu),
          ),
          BigButton(
            label: 'Nächste Runde',
            hint: 'Enter',
            icon: Icons.play_arrow_rounded,
            onPressed: () => Navigator.of(context).pop(ReviewExit.nextRound),
          ),
        ]),
      ]),
    );
  }
}
