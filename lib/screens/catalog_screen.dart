import 'package:flutter/material.dart';

import '../data/progress.dart';
import '../data/question_bank.dart';
import '../ui.dart';

/// Alle Fragen zum Nachlesen, mit Suche und eigener Statistik.
class CatalogScreen extends StatefulWidget {
  const CatalogScreen({super.key, required this.bank, required this.progress});
  final QuestionBank bank;
  final Progress progress;

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  String? _exam;
  String _query = '';
  bool _onlyWeak = false;

  @override
  Widget build(BuildContext context) {
    final q = _query.toLowerCase();
    final list = widget.bank.forExam(_exam).where((x) {
      if (_onlyWeak) {
        final (_, w) = widget.progress.statOf(x);
        if (w == 0 || widget.progress.isMastered(x)) return false;
      }
      if (q.isEmpty) return true;
      return x.frage.toLowerCase().contains(q) ||
          x.richtig.toLowerCase().contains(q) ||
          x.thema.toLowerCase().contains(q) ||
          x.erklaerung.toLowerCase().contains(q);
    }).toList();

    final byTopic = <String, List<Question>>{};
    for (final x in list) {
      byTopic.putIfAbsent('${x.pruefung} · ${x.thema}', () => []).add(x);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Fragenkatalog'),
        backgroundColor: const Color(0xFF141826),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1000),
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Wrap(
                spacing: 12,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 360,
                    child: TextField(
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: 'Suchen, z. B. Subnetz, SQL, Scrum …',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      onChanged: (v) => setState(() => _query = v),
                    ),
                  ),
                  SegmentedButton<String?>(
                    segments: const [
                      ButtonSegment(value: null, label: Text('Alle')),
                      ButtonSegment(value: 'AP1', label: Text('AP1')),
                      ButtonSegment(value: 'AP2', label: Text('AP2')),
                    ],
                    selected: {_exam},
                    showSelectedIcon: false,
                    onSelectionChanged: (v) => setState(() => _exam = v.first),
                  ),
                  FilterChip(
                    label: const Text('Nur schwache Fragen'),
                    selected: _onlyWeak,
                    onSelected: (v) => setState(() => _onlyWeak = v),
                  ),
                  Text('${list.length} Fragen',
                      style: const TextStyle(color: Colors.white60)),
                ],
              ),
            ),
            Expanded(
              child: list.isEmpty
                  ? const Center(child: Text('Keine Fragen gefunden.'))
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        for (final entry in byTopic.entries) ...[
                          Padding(
                            padding: const EdgeInsets.only(top: 12, bottom: 6),
                            child: Text(entry.key,
                                style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w800,
                                    color: kAccent)),
                          ),
                          for (final x in entry.value) _tile(x),
                        ],
                      ],
                    ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _tile(Question x) {
    final (c, w) = widget.progress.statOf(x);
    final mastered = widget.progress.isMastered(x);
    return Card(
      color: const Color(0xFF1A1F33),
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        leading: Icon(
          mastered
              ? Icons.check_circle
              : (w > 0 ? Icons.error_outline : Icons.circle_outlined),
          color: mastered ? kGood : (w > 0 ? kBad : Colors.white30),
        ),
        title: Text(x.frage, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text('✓ $c   ✗ $w',
            style: const TextStyle(color: Colors.white54, fontSize: 12)),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('✓ ${x.richtig}',
              style: const TextStyle(
                  color: kGood, fontWeight: FontWeight.w800, fontSize: 16)),
          const SizedBox(height: 4),
          for (final f in x.falsch)
            Text('✗ $f', style: const TextStyle(color: Colors.white54)),
          const SizedBox(height: 8),
          Text(x.erklaerung, style: const TextStyle(color: Colors.white)),
        ],
      ),
    );
  }
}
