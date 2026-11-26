import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../audio/sound.dart';
import '../data/progress.dart';
import '../data/question_bank.dart';
import '../ui.dart';

/// Lernkarten-Modus (Karteikasten-Prinzip): Frage lesen, Antwort aufdecken,
/// selbst bewerten. Schwierige Karten kommen schneller wieder.
/// Karten: cwillam AP1/AP2-Tracker, AGPL-3.0 (github.com/cwillam).
class FlashcardsScreen extends StatefulWidget {
  const FlashcardsScreen({super.key, required this.bank, required this.progress, this.exam});
  final QuestionBank bank;
  final Progress progress;
  final String? exam;

  @override
  State<FlashcardsScreen> createState() => _FlashcardsScreenState();
}

class _FlashcardsScreenState extends State<FlashcardsScreen> {
  static const _sessionSize = 20;
  static const _ratings = [
    ('Nicht gewusst', '1', kBad),
    ('Geraten', '2', Color(0xFFFFAB40)),
    ('Nachgedacht', '3', kAccent),
    ('Sofort gewusst', '4', kGood),
  ];

  late String? _exam = widget.exam;
  String? _topic;
  List<Flashcard> _queue = [];
  int _index = 0;
  bool _revealed = false;
  int _done = 0;
  int _xp = 0;
  final _rng = Random();

  Progress get p => widget.progress;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    _newSession();
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    if (_xp > 0) p.addXp(_xp);
    super.dispose();
  }

  List<Flashcard> get _pool {
    final all = widget.bank.cardsFor(_exam);
    return _topic == null ? all : all.where((c) => c.thema == _topic).toList();
  }

  void _newSession() {
    final pool = _pool;
    // Zuerst fällige Wiederholungen, dann neue Karten, gemischt
    final due = pool.where((c) => p.cardBox(c.id) != null && p.cardDue(c.id)).toList()..shuffle(_rng);
    final fresh = pool.where((c) => p.cardBox(c.id) == null).toList()..shuffle(_rng);
    var q = [...due, ...fresh].take(_sessionSize).toList();
    if (q.isEmpty) {
      // Alles gelernt und nichts fällig: zufällige Wiederholung
      q = (List.of(pool)..shuffle(_rng)).take(_sessionSize).toList();
    }
    setState(() {
      _queue = q;
      _index = 0;
      _revealed = false;
    });
  }

  Flashcard? get _card => _index < _queue.length ? _queue[_index] : null;

  Future<void> _rate(int r) async {
    final c = _card;
    if (c == null || !_revealed) return;
    await p.rateCard(c.id, r);
    Sound.instance.play(r >= 2 ? 'coin' : 'click');
    _xp += r >= 2 ? 3 : 1;
    _done++;
    // Nicht gewusst: Karte kommt in dieser Runde nochmal (nach 3 Karten)
    if (r == 0) _queue.insert(min(_index + 4, _queue.length), c);
    setState(() {
      _index++;
      _revealed = false;
    });
  }

  bool _onKey(KeyEvent e) {
    if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? false)) return false;
    if (e is! KeyDownEvent) return false;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.enter) {
      if (_card == null) {
        _newSession();
      } else if (!_revealed) {
        setState(() => _revealed = true);
      } else {
        _rate(2);
      }
      return true;
    }
    final digits = [
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
    ];
    final i = digits.indexOf(k);
    if (i >= 0 && _revealed) {
      _rate(i);
      return true;
    }
    if (k == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final all = widget.bank.cardsFor(_exam);
    final topics = <String>[];
    for (final c in all) {
      if (!topics.contains(c.thema)) topics.add(c.thema);
    }
    final pool = _pool;
    final learned = p.cardsLearned(pool.map((c) => c.id));
    return Scaffold(
      backgroundColor: const Color(0xFF0D1020),
      appBar: AppBar(
        title: const Text('Lernkarten'),
        backgroundColor: Colors.transparent,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text('$learned / ${pool.length} sicher gelernt',
                  style: const TextStyle(color: kGood, fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                SegmentedButton<String?>(
                  segments: const [
                    ButtonSegment(value: 'AP1', label: Text('AP1')),
                    ButtonSegment(value: 'AP2', label: Text('AP2')),
                    ButtonSegment(value: null, label: Text('Alle')),
                  ],
                  selected: {_exam},
                  onSelectionChanged: (v) {
                    _exam = v.first;
                    _topic = null;
                    _newSession();
                  },
                ),
                DropdownButton<String?>(
                  value: _topic,
                  hint: const Text('Alle Themen'),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('Alle Themen')),
                    for (final t in topics) DropdownMenuItem(value: t, child: Text(t)),
                  ],
                  onChanged: (v) {
                    _topic = v;
                    _newSession();
                  },
                ),
              ]),
              const SizedBox(height: 14),
              if (_queue.isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: min(1.0, _index / _queue.length),
                    minHeight: 6,
                    backgroundColor: Colors.white12,
                  ),
                ),
              const SizedBox(height: 14),
              _card == null ? _summary() : _cardView(_card!),
              const SizedBox(height: 18),
              const Text(
                'Karten: cwillam AP1/AP2-Tracker (github.com/cwillam), Lizenz AGPL-3.0.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: Colors.white38),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cardView(Flashcard c) {
    final box = p.cardBox(c.id);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Panel(
        padding: const EdgeInsets.all(24),
        border: kAccent.withValues(alpha: 0.5),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('${c.bereich} · ${c.thema}',
                style: const TextStyle(color: kAccent, fontWeight: FontWeight.w700)),
            const Spacer(),
            Text(box == null ? 'neu' : 'Fach ${box + 1}/7',
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ]),
          const SizedBox(height: 14),
          Text(c.frage, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
          const SizedBox(height: 18),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 180),
            crossFadeState: _revealed ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            firstChild: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => setState(() => _revealed = true),
                icon: const Icon(Icons.visibility),
                label: const Text('Antwort zeigen  (Leertaste)'),
              ),
            ),
            secondChild: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: kGood.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: kGood.withValues(alpha: 0.5)),
              ),
              child: SelectableText(c.antwort,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, height: 1.35)),
            ),
          ),
        ]),
      ),
      const SizedBox(height: 14),
      if (_revealed)
        Row(children: [
          for (var i = 0; i < 4; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: _ratings[i].$3,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: () => _rate(i),
                child: Column(children: [
                  Text(_ratings[i].$1, style: const TextStyle(fontWeight: FontWeight.w900)),
                  Text('Taste ${_ratings[i].$2}', style: const TextStyle(fontSize: 11)),
                ]),
              ),
            ),
          ],
        ]),
    ]);
  }

  Widget _summary() {
    return Panel(
      padding: const EdgeInsets.all(28),
      child: Column(children: [
        const Icon(Icons.emoji_events, color: kGold, size: 56),
        const SizedBox(height: 8),
        Text('Runde geschafft: $_done Karten', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
        const SizedBox(height: 4),
        Text('+$_xp XP (werden beim Verlassen gutgeschrieben)',
            style: const TextStyle(color: Color(0xFFB388FF))),
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: _newSession,
          icon: const Icon(Icons.replay),
          label: const Text('Nächste Runde  (Leertaste)'),
        ),
      ]),
    );
  }
}
