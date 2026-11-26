import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../audio/sound.dart';
import '../audio/youtube.dart';
import '../data/progress.dart';
import '../data/question_bank.dart';
import '../game/quality.dart';
import '../platform.dart';
import '../ui.dart';

/// Einstellungen: Musik (Spielmusik, eigene Dateien, YouTube-Links),
/// Grafik und eigene Fragen.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.progress, required this.bank});
  final Progress progress;
  final QuestionBank bank;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _yt = TextEditingController();
  String? _ytError;

  Progress get p => widget.progress;

  @override
  void dispose() {
    _yt.dispose();
    super.dispose();
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  // ------------------------------------------------------------------ Musik

  Future<void> _addMusic() async {
    final files = await FilePicker.pickFiles(
      dialogTitle: 'Musik auswählen',
      type: FileType.custom,
      allowedExtensions: const ['mp3', 'wav', 'm4a', 'aac', 'wma', 'flac'],
    );
    final paths = files.map((f) => f.path).whereType<String>().toList();
    if (paths.isEmpty) return;
    final lib = p.library;
    for (final f in paths) {
      if (lib.any((e) => e.value == f)) continue;
      lib.add(MusicEntry('file', f, f.split(Platform.pathSeparator).last));
    }
    await p.setLibrary(lib);
    if (mounted) setState(() {});
  }

  Future<void> _remove(int i) async {
    final lib = p.library..removeAt(i);
    await p.setLibrary(lib);
    if (Sound.instance.playingIndex.value == i) await Sound.instance.stopLibrary();
    setState(() {});
  }

  Future<void> _addYoutube() async {
    final text = _yt.text.trim();
    if (!YoutubePlayer.supported) {
      setState(() => _ytError = 'YouTube-Links gehen nur in der Windows-Version.');
      return;
    }
    if (YoutubePlayer.parse(text) == null) {
      setState(() => _ytError = 'Bitte einen YouTube-Link einfügen (https://…)');
      return;
    }
    final lib = p.library;
    if (!lib.any((e) => e.value == text)) {
      lib.add(MusicEntry('yt', text, await _youtubeTitle(text) ?? 'YouTube-Video'));
      await p.setLibrary(lib);
    }
    _yt.clear();
    if (mounted) setState(() => _ytError = null);
  }

  /// Titel über die öffentliche oEmbed-Schnittstelle von YouTube holen.
  static Future<String?> _youtubeTitle(String link) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final uri = Uri.https('www.youtube.com', '/oembed', {'url': link, 'format': 'json'});
      final res = await (await client.getUrl(uri)).close().timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) return null;
      final body = await res.transform(utf8.decoder).join();
      return (jsonDecode(body) as Map<String, dynamic>)['title'] as String?;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  // ----------------------------------------------------------------- Fragen

  Future<void> _importQuestions() async {
    final files = await FilePicker.pickFiles(
      dialogTitle: 'Fragen (JSON) importieren',
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    final path = files.isEmpty ? null : files.first.path;
    if (path == null) return;
    String raw;
    try {
      raw = await File(path).readAsString();
    } catch (_) {
      _snack('Datei konnte nicht gelesen werden.');
      return;
    }
    final parsed = QuestionBank.tryParse(raw);
    if (parsed == null || parsed.isEmpty) {
      _snack('Keine gültigen Fragen gefunden. Format siehe unten.');
      return;
    }
    final merged = [...widget.bank.custom];
    final known = widget.bank.all.map((q) => q.frage).toSet();
    var added = 0;
    for (final q in parsed) {
      if (known.add(q.frage)) {
        merged.add(q);
        added++;
      }
    }
    widget.bank.custom = merged;
    await p.setCustomQuestionsJson(_encode(merged));
    _snack('$added neue Fragen importiert (${parsed.length - added} doppelt).');
    setState(() {});
  }

  static String _encode(List<Question> qs) => jsonEncode([
        for (final q in qs)
          {
            'pruefung': q.pruefung,
            'thema': q.thema,
            'frage': q.frage,
            'richtig': q.richtig,
            'falsch': q.falsch,
            'erklaerung': q.erklaerung,
          }
      ]);

  Future<void> _removeCustom() async {
    widget.bank.custom = [];
    await p.setCustomQuestionsJson(null);
    _snack('Eigene Fragen entfernt.');
    setState(() {});
  }

  // ------------------------------------------------------------------ Build

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1020),
      appBar: AppBar(title: const Text('Einstellungen'), backgroundColor: Colors.transparent),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
            children: [
              _section(Icons.music_note, 'Musik & Sound', [
                SwitchListTile(
                  title: const Text('Musik'),
                  subtitle: const Text('Ganz stumm schalten geht auch mit dem Noten-Knopf im Menü und im Spiel'),
                  value: p.musicOn,
                  onChanged: (v) async {
                    await p.setMusicOn(v);
                    await Sound.instance.refresh();
                    setState(() {});
                  },
                ),
                _slider('Musik-Lautstärke', p.musicVolume, (v) async {
                  await Sound.instance.setMusicVolume(v);
                  setState(() {});
                }),
                SwitchListTile(
                  title: const Text('Soundeffekte'),
                  subtitle: const Text('Münzen, Sprung, richtig/falsch …'),
                  value: p.sfxOn,
                  onChanged: (v) async {
                    await p.setSfxOn(v);
                    setState(() {});
                  },
                ),
                _slider('Effekt-Lautstärke', p.sfxVolume, (v) async {
                  await p.setSfxVolume(v);
                  setState(() {});
                }, onEnd: () => Sound.instance.play('coin')),
                const SizedBox(height: 8),
                const Text('Musikquelle', style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 6),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'game', label: Text('Spielmusik'), icon: Icon(Icons.videogame_asset)),
                    ButtonSegment(value: 'library', label: Text('Meine Musik'), icon: Icon(Icons.library_music)),
                  ],
                  selected: {p.musicSource},
                  onSelectionChanged: (v) async {
                    if (v.first == 'game') {
                      await Sound.instance.stopLibrary();
                    } else {
                      await p.setMusicSource('library');
                      await Sound.instance.refresh();
                    }
                    setState(() {});
                  },
                ),
              ]),
              if (hasFileSystem)
              _section(Icons.library_music, 'Meine Musik', [
                const Text(
                    'Füge Musikdateien oder YouTube-Links hinzu und drück ▶. Die Musik läuft dann im Menü und beim Rennen, '
                    'nacheinander in dieser Reihenfolge. YouTube spielt nur den Ton ab, ohne Fenster.',
                    style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _yt,
                      decoration: InputDecoration(
                        hintText: 'YouTube-Link einfügen, z. B. https://youtu.be/…',
                        errorText: _ytError,
                        border: const OutlineInputBorder(),
                        isDense: true,
                        prefixIcon: const Icon(Icons.smart_display, color: Color(0xFFFF0033)),
                      ),
                      onSubmitted: (_) => _addYoutube(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: _addYoutube, child: const Text('Hinzufügen')),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _addMusic,
                    icon: const Icon(Icons.audio_file),
                    label: const Text('Datei'),
                  ),
                ]),
                const SizedBox(height: 8),
                ValueListenableBuilder<String?>(
                  valueListenable: Sound.instance.status,
                  builder: (_, msg, __) => msg == null
                      ? const SizedBox.shrink()
                      : Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text(msg, style: const TextStyle(color: Color(0xFFFFAB40))),
                        ),
                ),
                ValueListenableBuilder<int>(
                  valueListenable: Sound.instance.changed,
                  builder: (_, __, ___) => ValueListenableBuilder<int?>(
                    valueListenable: Sound.instance.playingIndex,
                    builder: (_, playing, __) {
                      final lib = p.library;
                      if (lib.isEmpty) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Text('Noch leer.', style: TextStyle(color: Colors.white38)),
                        );
                      }
                      return Column(children: [
                        for (var i = 0; i < lib.length; i++)
                          ListTile(
                            dense: true,
                            selected: playing == i,
                            selectedTileColor: kAccent.withValues(alpha: 0.12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            leading: IconButton.filled(
                              style: IconButton.styleFrom(
                                backgroundColor: playing == i ? kGood : kAccent,
                                foregroundColor: Colors.black,
                              ),
                              tooltip: playing == i ? 'Stopp' : 'Abspielen',
                              icon: Icon(playing == i ? Icons.stop : Icons.play_arrow),
                              onPressed: () async {
                                if (playing == i) {
                                  await Sound.instance.stopLibrary();
                                } else {
                                  await Sound.instance.playLibrary(i);
                                }
                                if (mounted) setState(() {});
                              },
                            ),
                            title: Text(lib[i].title, maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(lib[i].isYoutube ? 'YouTube' : lib[i].value,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            trailing: IconButton(
                              tooltip: 'Entfernen',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _remove(i),
                            ),
                          ),
                      ]);
                    },
                  ),
                ),
              ]),
              _section(Icons.slow_motion_video, 'Zeitlupe bei Fragen', [
                const Text(
                    'Sobald eine Frage erscheint, läuft das Spiel langsamer, damit du in Ruhe lesen kannst. '
                    'Wenn du dir sicher bist: Spur wählen und LEERTASTE drücken – die Antwort ist festgelegt und es geht normal weiter.',
                    style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 10),
                SegmentedButton<double>(
                  segments: const [
                    ButtonSegment(value: 1.0, label: Text('Aus')),
                    ButtonSegment(value: 0.75, label: Text('Leicht (75 %)')),
                    ButtonSegment(value: 0.5, label: Text('Mittel (50 %)')),
                    ButtonSegment(value: 0.3, label: Text('Stark (30 %)')),
                    ButtonSegment(value: 0.15, label: Text('Sehr stark (15 %)')),
                  ],
                  selected: {p.slowmo},
                  onSelectionChanged: (v) async {
                    await p.setSlowmo(v.first);
                    setState(() {});
                  },
                ),
              ]),
              _section(Icons.speed, 'Grafik & Leistung', [
                const Text(
                    'Auto misst die Bildrate und schaltet bei Ruckeln automatisch eine Stufe runter.',
                    style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 8),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'auto', label: Text('Auto')),
                    ButtonSegment(value: 'high', label: Text('Hoch')),
                    ButtonSegment(value: 'mid', label: Text('Mittel')),
                    ButtonSegment(value: 'low', label: Text('Niedrig')),
                  ],
                  selected: {p.quality},
                  onSelectionChanged: (v) async {
                    await p.setQuality(v.first);
                    QualityGovernor.instance.setMode(v.first);
                    setState(() {});
                  },
                ),
                SwitchListTile(
                  title: const Text('FPS anzeigen'),
                  value: p.showFps,
                  onChanged: (v) async {
                    await p.setShowFps(v);
                    setState(() {});
                  },
                ),
              ]),
              _section(Icons.quiz, 'Eigene Fragen', [
                Text(
                    'Eingebaut: ${widget.bank.builtIn.length} Fragen · Lernkarten: ${widget.bank.cards.length} (davon ${widget.bank.cardQuestions.length} im Lauf) · Eigene: ${widget.bank.custom.length}',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                const Text(
                    'Importiere eine JSON-Datei mit Fragen, z. B. von deiner Lerngruppe. Jede Frage braucht genau eine richtige und mindestens zwei falsche Antworten:',
                    style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.black38,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const SelectableText(
                    '[{"pruefung":"AP1","thema":"Netzwerk","frage":"Welcher Port nutzt HTTPS standardmäßig?",\n'
                    '  "richtig":"443","falsch":["80","21","25"],"erklaerung":"HTTPS = HTTP über TLS auf Port 443."}]',
                    style: TextStyle(fontFamily: 'Consolas', fontSize: 12),
                  ),
                ),
                const SizedBox(height: 10),
                if (hasFileSystem)
                Wrap(spacing: 10, children: [
                  FilledButton.icon(
                      onPressed: _importQuestions,
                      icon: const Icon(Icons.upload_file),
                      label: const Text('JSON importieren')),
                  if (widget.bank.custom.isNotEmpty)
                    OutlinedButton.icon(
                        onPressed: _removeCustom,
                        icon: const Icon(Icons.delete_sweep),
                        label: const Text('Eigene Fragen entfernen')),
                ]),
              ]),
              _section(Icons.gavel, 'Lizenz & Quellen', const [
                Text(
                    'Dieses Spiel steht unter der GNU AGPL-3.0. Die Lernkarten stammen aus den '
                    'Open-Source-Projekten von cwillam (github.com/cwillam/ap1-tracker, ap2-tracker, '
                    'ap2-fisi-tracker), ebenfalls AGPL-3.0.',
                    style: TextStyle(color: Colors.white70)),
                SizedBox(height: 6),
                Text(
                    'Wenn du das Spiel weitergibst, gib den Quellcode mit (z. B. als ZIP) – so verlangt es die AGPL.',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _section(IconData icon, String title, List<Widget> children) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Panel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(icon, color: kAccent),
              const SizedBox(width: 8),
              Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
            ]),
            const SizedBox(height: 10),
            ...children,
          ]),
        ),
      );

  Widget _slider(String label, double value, ValueChanged<double> onChanged, {VoidCallback? onEnd}) =>
      Row(children: [
        SizedBox(width: 150, child: Text(label)),
        Expanded(
          child: Slider(
            value: value,
            onChanged: onChanged,
            onChangeEnd: onEnd == null ? null : (_) => onEnd(),
          ),
        ),
        SizedBox(width: 44, child: Text('${(value * 100).round()} %')),
      ]);
}
