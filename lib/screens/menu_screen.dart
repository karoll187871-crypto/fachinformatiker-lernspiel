import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../audio/sound.dart';
import '../data/account.dart';
import '../data/cosmetics.dart';
import '../data/progress.dart';
import '../data/question_bank.dart';
import '../data/quests.dart';
import '../game/engine.dart';
import '../game/renderer.dart';
import '../platform.dart';
import '../ui.dart';
import 'account_screen.dart';
import 'catalog_screen.dart';
import 'flashcards_screen.dart';
import 'game_screen.dart';
import 'settings_screen.dart';
import 'shop_screen.dart';

class _Mode {
  const _Mode(this.key, this.exam, this.title, this.subtitle, this.color);
  final String key;
  final String? exam;
  final String title;
  final String subtitle;
  final Color color;
}

const _modes = [
  _Mode('ap1', 'AP1', 'AP1', 'Teil 1 · IT-Arbeitsplatz', Color(0xFF29B6F6)),
  _Mode('ap2', 'AP2', 'AP2', 'Teil 2 · Entwicklung & WiSo', Color(0xFFAB47BC)),
  _Mode('mix', null, 'Gemischt', 'Alle Fragen', Color(0xFF26A69A)),
];

class MenuScreen extends StatefulWidget {
  const MenuScreen({super.key, required this.bank, required this.progress});
  final QuestionBank bank;
  final Progress progress;

  @override
  State<MenuScreen> createState() => _MenuScreenState();
}

class _Repaint extends ChangeNotifier {
  void tick() => notifyListeners();
}

class _MenuScreenState extends State<MenuScreen>
    with SingleTickerProviderStateMixin {
  late RunnerGame _demo = _makeDemo();

  RunnerGame _makeDemo() => RunnerGame(
        demo: true,
        seed: 3,
        look: widget.progress.skin.look,
        trailColors: widget.progress.trail.colors,
      );
  final _repaint = _Repaint();
  late final Ticker _ticker;
  Duration _last = Duration.zero;

  int _modeIndex = 2;
  final Set<String> _topics = {};
  late Tempo _tempo;

  @override
  void initState() {
    super.initState();
    _tempo = Tempo.byName(widget.progress.tempo);
    _ticker = createTicker((elapsed) {
      final dt = ((elapsed - _last).inMicroseconds / 1e6).clamp(0.0, 0.05);
      _last = elapsed;
      _demo.update(dt);
      _repaint.tick();
    })
      ..start();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  _Mode get _mode => _modes[_modeIndex];

  List<Question> get _pool {
    final base = widget.bank.forExam(_mode.exam);
    if (_topics.isEmpty) return base;
    return base.where((q) => _topics.contains(q.thema)).toList();
  }

  String get _modeKey =>
      _topics.isEmpty ? _mode.key : '${_mode.key}_${(_topics.toList()..sort()).join('+')}';

  bool _onKey(KeyEvent e) {
    if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? false)) return false;
    if (e is! KeyDownEvent || HardwareKeyboard.instance.isAltPressed) {
      return false;
    }
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.space) {
      _start();
      return true;
    }
    if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.keyA) {
      _selectMode((_modeIndex + 2) % 3);
      return true;
    }
    if (k == LogicalKeyboardKey.arrowRight || k == LogicalKeyboardKey.keyD) {
      _selectMode((_modeIndex + 1) % 3);
      return true;
    }
    return false;
  }

  void _selectMode(int i) => setState(() {
        _modeIndex = i;
        _topics.clear();
      });

  Future<void> _start() async {
    final pool = _pool;
    if (pool.length < 3) return;
    _ticker.stop();
    await Navigator.of(context).push(PageRouteBuilder<void>(
      transitionDuration: const Duration(milliseconds: 350),
      pageBuilder: (_, __, ___) => GameScreen(
        pool: pool,
        progress: widget.progress,
        modeKey: _modeKey,
        modeLabel: _topics.isEmpty
            ? _mode.title
            : '${_mode.title} · ${_topics.length} Themen',
        tempo: _tempo,
      ),
      transitionsBuilder: (_, a, __, child) =>
          FadeTransition(opacity: a, child: child),
    ));
    if (!mounted) return;
    _last = Duration.zero;
    _ticker.start();
    setState(() {});
  }

  Future<void> _openCatalog() => _openPage(
      (_) => CatalogScreen(bank: widget.bank, progress: widget.progress));

  Future<void> _openCards() => _openPage((_) => FlashcardsScreen(
      bank: widget.bank, progress: widget.progress, exam: _mode.exam));

  Future<void> _openAccount() =>
      _openPage((_) => AccountScreen(progress: widget.progress));

  Future<void> _openShop() =>
      _openPage((_) => ShopScreen(progress: widget.progress));

  Future<void> _openSettings() => _openPage(
      (_) => SettingsScreen(progress: widget.progress, bank: widget.bank));

  Future<void> _openPage(WidgetBuilder builder) async {
    Sound.instance.play('click');
    _ticker.stop();
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: builder));
    if (!mounted) return;
    _last = Duration.zero;
    _demo = _makeDemo();
    _ticker.start();
    setState(() {});
    Account.instance.scheduleUpload();
  }

  Future<void> _claim(Quest q) async {
    final before = widget.progress.level;
    if (await widget.progress.claimQuest(q)) {
      Sound.instance.play(widget.progress.level > before ? 'levelup' : 'buy');
      setState(() {});
      Account.instance.scheduleUpload();
    }
  }

  Future<void> _resetStats() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Lernstatistik zurücksetzen?'),
        content: const Text(
            'Alle „gemeistert“-Markierungen und Fehlerzähler werden gelöscht. Highscores bleiben erhalten.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Zurücksetzen')),
        ],
      ),
    );
    if (ok ?? false) {
      await widget.progress.resetStats();
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LayoutBuilder(builder: (context, c) {
        final portrait = isPortrait(c.biggest);
        final s = portrait ? uiScale(c.biggest) : min(uiScale(c.biggest), c.maxHeight / 760);
        return Stack(
          fit: StackFit.expand,
          children: [
            RepaintBoundary(
              child: CustomPaint(
                  painter: RunnerPainter(_demo, _repaint),
                  size: c.biggest,
                  isComplex: true,
                  willChange: true),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [
                  Colors.black.withValues(alpha: 0.82),
                  Colors.black.withValues(alpha: 0.45),
                  Colors.black.withValues(alpha: 0.0),
                ], stops: const [0, 0.5, 0.85]),
              ),
            ),
            Positioned(
              right: 16 * s,
              top: 12 * s,
              child: Row(children: [
                ValueListenableBuilder<int>(
                  valueListenable: Sound.instance.changed,
                  builder: (_, __, ___) => _iconBtn(
                      widget.progress.musicOn ? Icons.music_note : Icons.music_off,
                      widget.progress.musicOn ? 'Musik aus' : 'Musik an',
                      Sound.instance.toggleMute,
                      s),
                ),
                SizedBox(width: 8 * s),
                ValueListenableBuilder<int>(
                  valueListenable: Account.instance.changed,
                  builder: (_, __, ___) => _iconBtn(
                      Account.instance.loggedIn ? Icons.cloud_done : Icons.account_circle,
                      Account.instance.loggedIn
                          ? 'Konto: ${Account.instance.email}'
                          : 'Konto erstellen / anmelden (Spielstand auf allen Geräten)',
                      _openAccount,
                      s),
                ),
                SizedBox(width: 8 * s),
                _iconBtn(Icons.settings, 'Einstellungen: Musik, Grafik, Fragen', _openSettings, s),
                if (isDesktop) ...[
                  SizedBox(width: 8 * s),
                  _iconBtn(Icons.fullscreen, 'Vollbild (F11)', AppWindow.toggleFullscreen, s),
                  SizedBox(width: 8 * s),
                  _iconBtn(Icons.power_settings_new, 'Beenden', AppWindow.quit, s),
                ],
              ]),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: SingleChildScrollView(
                padding: portrait
                    ? EdgeInsets.fromLTRB(14, 64 * s, 14, 24)
                    : EdgeInsets.fromLTRB(48 * s, 24 * s, 24 * s, 24 * s),
                child: SizedBox(
                  width: portrait ? c.maxWidth - 28 : min(620 * s, c.maxWidth - 72 * s),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _content(s),
                      // Schmale Fenster: Story und Quests unten anhängen
                      if (c.maxWidth < 1150 * s) ...[
                        SizedBox(height: 18 * s),
                        _sidePanel(s),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            if (c.maxWidth >= 1150 * s)
              Positioned(
                right: 24 * s,
                top: 72 * s,
                bottom: 24 * s,
                width: 400 * s,
                child: SingleChildScrollView(child: _sidePanel(s)),
              ),
          ],
        );
      }),
    );
  }

  Widget _iconBtn(IconData icon, String tip, VoidCallback onTap, double s) =>
      Tooltip(
        message: tip,
        child: IconButton.filledTonal(
          iconSize: 24 * s,
          onPressed: onTap,
          icon: Icon(icon),
        ),
      );

  TextStyle _t(double size, double s, {FontWeight w = FontWeight.w700, Color? c}) =>
      TextStyle(fontSize: size * s, fontWeight: w, color: c ?? Colors.white);

  Widget _content(double s) {
    final topics = widget.bank.topics(_mode.exam);
    final pool = _pool;
    final mastered = widget.progress.masteredCount(pool);
    final hs = widget.progress.highscore(_modeKey);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('FACHINFORMATIKER',
            style: _t(15, s, c: kAccent, w: FontWeight.w800)
                .copyWith(letterSpacing: 6 * s)),
        Text('Prüfungs-Runner',
            style: _t(54, s, w: FontWeight.w900).copyWith(height: 1.05)),
        SizedBox(height: 6 * s),
        Text('Renn durch das richtige Tor. Weich Zügen aus. Sammle Power-ups. Bestehe AP1 & AP2.',
            style: _t(17, s, c: Colors.white70, w: FontWeight.w500)),
        SizedBox(height: 24 * s),
        Row(children: [
          for (var i = 0; i < _modes.length; i++) ...[
            if (i > 0) SizedBox(width: 10 * s),
            Expanded(child: _modeCard(i, s)),
          ],
        ]),
        SizedBox(height: 16 * s),
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            dense: true,
            title: Text(
                _topics.isEmpty
                    ? 'Themen auswählen (optional) · ${topics.length} Themen'
                    : 'Themen: ${_topics.length} ausgewählt',
                style: _t(14, s, c: Colors.white70)),
            children: [
              Wrap(
                spacing: 6 * s,
                runSpacing: 6 * s,
                children: [
                  for (final t in topics)
                    FilterChip(
                      label: Text(t, style: TextStyle(fontSize: 12 * s)),
                      selected: _topics.contains(t),
                      onSelected: (v) => setState(() => v ? _topics.add(t) : _topics.remove(t)),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
              SizedBox(height: 8 * s),
            ],
          ),
        ),
        SizedBox(height: 6 * s),
        Wrap(
          spacing: 14 * s,
          runSpacing: 8 * s,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              Switch(
                value: widget.bank.includeCards,
                onChanged: (v) async {
                  widget.bank.includeCards = v;
                  _topics.clear();
                  await widget.progress.setIncludeCards(v);
                  setState(() {});
                },
              ),
              SizedBox(width: 6 * s),
              Tooltip(
                message: 'Lernkarten aus den cwillam-Trackern (AGPL-3.0) als Fragen im Lauf',
                child: Text('+ ${widget.bank.cardQuestions.length} Lernkarten im Lauf',
                    style: _t(13, s, c: Colors.white70)),
              ),
            ]),
            Row(mainAxisSize: MainAxisSize.min, children: [
              Text('AP2-Richtung', style: _t(13, s, c: Colors.white70)),
              SizedBox(width: 8 * s),
              SegmentedButton<String>(
                segments: [
                  for (final t in const ['beide', 'FIAE', 'FISI'])
                    ButtonSegment(
                        value: t,
                        label: Text(t == 'beide' ? 'Beide' : t, style: TextStyle(fontSize: 12 * s))),
                ],
                selected: {widget.bank.ap2Track},
                showSelectedIcon: false,
                onSelectionChanged: (v) async {
                  widget.bank.ap2Track = v.first;
                  _topics.clear();
                  await widget.progress.setAp2Track(v.first);
                  setState(() {});
                },
              ),
            ]),
          ],
        ),
        SizedBox(height: 16 * s),
        Row(children: [
          Text('Tempo', style: _t(14, s, c: Colors.white70)),
          SizedBox(width: 12 * s),
          SegmentedButton<Tempo>(
            segments: [
              for (final t in Tempo.values)
                ButtonSegment(
                  value: t,
                  label: Text(t.label, style: TextStyle(fontSize: 13 * s)),
                  tooltip: t.crashCostsLife ? null : 'Unfälle kosten kein Leben, nur falsche Antworten',
                ),
            ],
            selected: {_tempo},
            showSelectedIcon: false,
            onSelectionChanged: (v) {
              setState(() => _tempo = v.first);
              widget.progress.setTempo(v.first.name);
            },
          ),
        ]),
        SizedBox(height: 20 * s),
        Panel(
          padding: EdgeInsets.all(14 * s),
          radius: 14 * s,
          child: Row(children: [
            _info('${pool.length}', 'Fragen', s),
            _info('$mastered', 'gemeistert', s, c: kGood),
            _info('$hs', 'Rekord', s, c: kGold),
            _info('${widget.progress.totalCoins}', 'Münzen gesamt', s, c: kGold),
          ]),
        ),
        SizedBox(height: 20 * s),
        Wrap(spacing: 12 * s, runSpacing: 10 * s, children: [
          BigButton(
            label: 'Los geht’s',
            hint: 'Enter',
            icon: Icons.play_arrow_rounded,
            scale: s * 1.15,
            onPressed: pool.length >= 3 ? _start : () {},
          ),
          BigButton(
            label: 'Lernkarten',
            icon: Icons.style_rounded,
            color: const Color(0xFFB388FF),
            scale: s,
            onPressed: _openCards,
          ),
          BigButton(
            label: 'Shop',
            icon: Icons.storefront_rounded,
            color: kGold,
            scale: s,
            onPressed: _openShop,
          ),
          BigButton(
            label: 'Fragenkatalog',
            icon: Icons.menu_book_rounded,
            color: Colors.white70,
            scale: s,
            onPressed: _openCatalog,
          ),
        ]),
        SizedBox(height: 10 * s),
        TextButton.icon(
          onPressed: _resetStats,
          icon: Icon(Icons.restart_alt, size: 18 * s),
          label: Text('Lernstatistik zurücksetzen', style: TextStyle(fontSize: 13 * s)),
        ),
        SizedBox(height: 14 * s),
        if (isDesktop)
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 4 * s,
          runSpacing: 6 * s,
          children: [
            KeyCap('A', size: 12 * s),
            KeyCap('D', size: 12 * s),
            Text(' Spur  ', style: _t(13, s, c: Colors.white60)),
            KeyCap('W', size: 12 * s),
            KeyCap('Leertaste', size: 12 * s),
            Text(' Springen  ', style: _t(13, s, c: Colors.white60)),
            KeyCap('S', size: 12 * s),
            Text(' Rollen  ', style: _t(13, s, c: Colors.white60)),
            KeyCap('F11', size: 12 * s),
            Text(' Vollbild', style: _t(13, s, c: Colors.white60)),
          ],
        ),
      ],
    );
  }

  Widget _sidePanel(double s) {
    final p = widget.progress;
    final lvl = p.level;
    final xp = p.xp;
    final cur = xpForLevel(lvl), next = xpForLevel(lvl + 1);
    final chapter = chapterForLevel(lvl);
    final upcoming = nextChapter(lvl);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Panel(
        padding: EdgeInsets.all(16 * s),
        radius: 16 * s,
        border: const Color(0xFFB388FF).withValues(alpha: 0.6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              padding: EdgeInsets.symmetric(horizontal: 10 * s, vertical: 4 * s),
              decoration: BoxDecoration(
                color: const Color(0xFFB388FF),
                borderRadius: BorderRadius.circular(10 * s),
              ),
              child: Text('Level $lvl',
                  style: _t(15, s, c: Colors.black, w: FontWeight.w900)),
            ),
            SizedBox(width: 10 * s),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(5 * s),
                  child: LinearProgressIndicator(
                    value: ((xp - cur) / max(1, next - cur)).clamp(0.0, 1.0),
                    minHeight: 9 * s,
                    color: const Color(0xFFB388FF),
                    backgroundColor: Colors.white12,
                  ),
                ),
                SizedBox(height: 3 * s),
                Text('${xp - cur} / ${next - cur} XP bis Level ${lvl + 1}',
                    style: _t(11, s, c: Colors.white60, w: FontWeight.w500)),
              ]),
            ),
          ]),
          SizedBox(height: 12 * s),
          Text('KAPITEL ${kChapters.indexOf(chapter) + 1}',
              style: _t(11, s, c: kAccent, w: FontWeight.w800)
                  .copyWith(letterSpacing: 3 * s)),
          Text(chapter.title, style: _t(20, s, w: FontWeight.w900)),
          SizedBox(height: 4 * s),
          Text(chapter.story, style: _t(13, s, c: Colors.white70, w: FontWeight.w500)),
          if (upcoming != null) ...[
            SizedBox(height: 6 * s),
            Text('Nächstes Kapitel „${upcoming.title}“ ab Level ${upcoming.level}',
                style: _t(11, s, c: Colors.white38, w: FontWeight.w500)),
          ],
        ]),
      ),
      SizedBox(height: 12 * s),
      Panel(
        padding: EdgeInsets.all(16 * s),
        radius: 16 * s,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.flag_rounded, color: kGold, size: 20 * s),
            SizedBox(width: 6 * s),
            Text('Tagesquests', style: _t(17, s, w: FontWeight.w900)),
            const Spacer(),
            Text('neu ab Mitternacht', style: _t(11, s, c: Colors.white38, w: FontWeight.w500)),
          ]),
          SizedBox(height: 8 * s),
          for (final q in p.quests) _questRow(q, s),
        ]),
      ),
    ]);
  }

  Widget _questRow(Quest q, double s) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 6 * s),
      child: Row(children: [
        Icon(q.claimed ? Icons.check_circle : (q.done ? Icons.redeem : Icons.radio_button_unchecked),
            color: q.claimed ? kGood : (q.done ? kGold : Colors.white38), size: 20 * s),
        SizedBox(width: 8 * s),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(q.text,
                style: _t(13, s,
                    c: q.claimed ? Colors.white38 : Colors.white, w: FontWeight.w600)),
            SizedBox(height: 3 * s),
            Row(children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3 * s),
                  child: LinearProgressIndicator(
                    value: q.progress / q.target,
                    minHeight: 5 * s,
                    color: q.done ? kGood : kAccent,
                    backgroundColor: Colors.white12,
                  ),
                ),
              ),
              SizedBox(width: 6 * s),
              Text('${q.progress}/${q.target}',
                  style: _t(11, s, c: Colors.white60, w: FontWeight.w500)),
            ]),
          ]),
        ),
        SizedBox(width: 8 * s),
        if (q.done && !q.claimed)
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: kGold,
              foregroundColor: Colors.black,
              padding: EdgeInsets.symmetric(horizontal: 10 * s, vertical: 6 * s),
              minimumSize: Size.zero,
            ),
            onPressed: () => _claim(q),
            child: Text('+${q.reward}  ·  +${q.xp} XP',
                style: TextStyle(fontSize: 12 * s, fontWeight: FontWeight.w800)),
          )
        else
          Row(mainAxisSize: MainAxisSize.min, children: [
            Text('${q.reward}', style: _t(12, s, c: q.claimed ? Colors.white30 : kGold)),
            SizedBox(width: 3 * s),
            Icon(Icons.monetization_on,
                size: 14 * s, color: q.claimed ? Colors.white30 : kGold),
          ]),
      ]),
    );
  }

  Widget _info(String v, String label, double s, {Color? c}) => Expanded(
        child: Column(children: [
          Text(v, style: _t(22, s, w: FontWeight.w900, c: c)),
          Text(label, style: _t(12, s, c: Colors.white60, w: FontWeight.w500)),
        ]),
      );

  Widget _modeCard(int i, double s) {
    final m = _modes[i];
    final selected = i == _modeIndex;
    final count = widget.bank.forExam(m.exam).length;
    return InkWell(
      borderRadius: BorderRadius.circular(16 * s),
      onTap: () => _selectMode(i),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: EdgeInsets.all(14 * s),
        decoration: BoxDecoration(
          color: m.color.withValues(alpha: selected ? 0.32 : 0.10),
          borderRadius: BorderRadius.circular(16 * s),
          border: Border.all(color: selected ? m.color : Colors.white24, width: selected ? 2.5 * s : 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(m.title, maxLines: 1, style: _t(26, s, w: FontWeight.w900)),
            ),
            Text(m.subtitle, style: _t(12, s, c: Colors.white70, w: FontWeight.w500)),
            SizedBox(height: 6 * s),
            Text('$count Fragen', style: _t(12, s, c: m.color)),
          ],
        ),
      ),
    );
  }
}
