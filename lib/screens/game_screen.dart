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
import '../game/quality.dart';
import '../game/renderer.dart';
import '../platform.dart';
import '../ui.dart';
import 'review_screen.dart';

class GameScreen extends StatefulWidget {
  const GameScreen({
    super.key,
    required this.pool,
    required this.progress,
    required this.modeKey,
    required this.modeLabel,
    required this.tempo,
  });

  final List<Question> pool;
  final Progress progress;
  final String modeKey;
  final String modeLabel;
  final Tempo tempo;

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _Repaint extends ChangeNotifier {
  void tick() => notifyListeners();
}

class _GameScreenState extends State<GameScreen>
    with SingleTickerProviderStateMixin {
  late RunnerGame game;
  late final Ticker _ticker;
  final _repaint = _Repaint();
  final _hud = _Repaint();
  Duration _last = Duration.zero;
  bool _newRecord = false;
  bool _resultSaved = false;
  RunResult? _result;
  double _hudAcc = 0;
  int _hudSig = 0;

  @override
  void initState() {
    super.initState();
    _newGame();
    _ticker = createTicker(_tick)..start();
    HardwareKeyboard.instance.addHandler(_onKey);
    Sound.instance.setScene('run');
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _ticker.dispose();
    _repaint.dispose();
    _hud.dispose();
    Sound.instance.setScene('menu');
    super.dispose();
  }

  void _newGame() {
    _newRecord = false;
    _resultSaved = false;
    _result = null;
    final p = widget.progress;
    game = RunnerGame(
      deck: QuestionDeck(widget.pool, p, Random()),
      tempo: widget.tempo,
      onAnswer: (q, ok) => p.record(q, correct: ok),
      onGameOver: _onGameOver,
      onSound: Sound.instance.game,
      look: p.skin.look,
      trailColors: p.trail.colors,
      slowmo: p.slowmo,
    );
    _reviewDone = false;
  }

  bool _reviewDone = false;

  /// Fragen, die in diesem Lauf mindestens einmal falsch waren.
  List<Question> get _wrongQuestions {
    final out = <Question>[];
    for (final a in game.answers) {
      if (!a.correct && !out.contains(a.question)) out.add(a.question);
    }
    return out;
  }

  Future<void> _startReview() async {
    final qs = _wrongQuestions;
    if (qs.isEmpty || _reviewDone) return;
    final res = await Navigator.of(context).push(PageRouteBuilder<ReviewExit>(
      transitionDuration: const Duration(milliseconds: 250),
      pageBuilder: (_, __, ___) => ReviewScreen(questions: qs, progress: widget.progress),
      transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
    ));
    if (!mounted) return;
    setState(() => _reviewDone = true);
    _hud.tick();
    Account.instance.scheduleUpload();
    if (res == ReviewExit.nextRound) {
      _restart();
    } else if (res == ReviewExit.menu) {
      _exit();
    }
  }

  Future<void> _onGameOver() async {
    if (_resultSaved) return;
    _resultSaved = true;
    final p = widget.progress;
    final stats = game.stats;
    if (game.phase != Phase.gameOver) {
      stats.distance = game.distance.floor();
    }
    final rec = await p.submitScore(widget.modeKey, game.score);
    await p.addCoins(game.coins);
    final levelBefore = p.level;
    final levels = await p.addXp(stats.xp);
    final quests = await p.applyRun(stats);
    if (levels > 0) Sound.instance.play('levelup');
    Account.instance.scheduleUpload();
    if (mounted) {
      setState(() {
        _newRecord = rec;
        _result = RunResult(stats.xp, levelBefore, p.level, quests);
      });
      _hud.tick();
    }
  }

  void _tick(Duration elapsed) {
    final dt = ((elapsed - _last).inMicroseconds / 1e6).clamp(0.0, 0.05);
    _last = elapsed;
    game.update(dt);
    _repaint.tick();
    // Die Oberfläche (HUD) nur bei Änderungen bzw. 12× pro Sekunde neu bauen,
    // das spart viel Rechenzeit.
    final g = game;
    final sig = Object.hash(g.phase, g.lives, g.activeGate, g.toast, g.explaining,
        g.powers.length, g.streak, (g.px / kLaneWidth).round(), g.countdown.ceil(),
        g.answerLocked);
    _hudAcc += dt;
    if (sig != _hudSig || _hudAcc >= 0.083) {
      _hudSig = sig;
      _hudAcc = 0;
      _hud.tick();
    }
  }

  void _restart() {
    setState(_newGame);
    _hud.tick();
  }

  void _togglePause() {
    game.togglePause();
    _hud.tick();
  }

  void _continue() {
    game.continueAfterExplanation();
    _hud.tick();
  }

  void _exit() {
    if (game.phase != Phase.gameOver && game.answers.isNotEmpty) {
      _onGameOver();
    }
    Navigator.of(context).pop();
  }

  // ---------------------------------------------------------------- Tasten

  static final _left = {LogicalKeyboardKey.arrowLeft, LogicalKeyboardKey.keyA};
  static final _right = {LogicalKeyboardKey.arrowRight, LogicalKeyboardKey.keyD};
  static final _up = {
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.keyW,
    LogicalKeyboardKey.space
  };
  static final _down = {LogicalKeyboardKey.arrowDown, LogicalKeyboardKey.keyS};
  static final _pause = {LogicalKeyboardKey.escape, LogicalKeyboardKey.keyP};
  static final _confirm = {
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.space
  };

  bool _onKey(KeyEvent e) {
    if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? false)) return false;
    if (e is KeyUpEvent) return false;
    final k = e.logicalKey;
    if (HardwareKeyboard.instance.isAltPressed) return false;
    final down = e is KeyDownEvent;
    switch (game.phase) {
      case Phase.explaining:
        if (_confirm.contains(k)) {
          if (down) _continue();
          return true;
        }
      case Phase.gameOver:
        if (!down) return false;
        if (_confirm.contains(k)) {
          if (_wrongQuestions.isNotEmpty && !_reviewDone) {
            _startReview();
          } else {
            _restart();
          }
          return true;
        }
        if (k == LogicalKeyboardKey.escape) {
          _exit();
          return true;
        }
      case Phase.paused:
        if (!down) return false;
        if (_pause.contains(k) || _confirm.contains(k)) {
          _togglePause();
          return true;
        }
        if (k == LogicalKeyboardKey.keyM) {
          _exit();
          return true;
        }
      case Phase.running:
      case Phase.countdown:
        if (!down) {
          return _left.contains(k) ||
              _right.contains(k) ||
              _up.contains(k) ||
              _down.contains(k);
        }
        // Zeitlupe: Leertaste/Enter legt die Antwort fest
        if (game.slowmoActive &&
            (k == LogicalKeyboardKey.space ||
                k == LogicalKeyboardKey.enter ||
                k == LogicalKeyboardKey.numpadEnter)) {
          if (game.confirmAnswer()) {
            Sound.instance.play('click');
            _hud.tick();
          }
          return true;
        }
        if (_left.contains(k)) {
          game.moveLeft();
        } else if (_right.contains(k)) {
          game.moveRight();
        } else if (_up.contains(k)) {
          game.jump();
        } else if (_down.contains(k)) {
          game.roll();
        } else if (_pause.contains(k)) {
          _togglePause();
        } else {
          return false;
        }
        return true;
    }
    return false;
  }

  // Wischgesten (Touchscreen / Maus)
  Offset _dragStart = Offset.zero;
  bool _dragUsed = false;

  void _onTap() {
    if (game.slowmoActive && game.confirmAnswer()) {
      Sound.instance.play('click');
      _hud.tick();
    }
  }

  void _onPanStart(DragStartDetails d) {
    _dragStart = d.localPosition;
    _dragUsed = false;
  }

  void _onPanUpdate(DragUpdateDetails d) {
    if (_dragUsed) return;
    final delta = d.localPosition - _dragStart;
    if (delta.distance < 40) return;
    _dragUsed = true;
    if (delta.dx.abs() > delta.dy.abs()) {
      delta.dx < 0 ? game.moveLeft() : game.moveRight();
    } else {
      delta.dy < 0 ? game.jump() : game.roll();
    }
  }

  // ------------------------------------------------------------------ Build

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: game.phase == Phase.paused || game.phase == Phase.gameOver,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          _onGameOver();
          return;
        }
        if (game.phase == Phase.running) _togglePause();
      },
      child: Scaffold(
      backgroundColor: Colors.black,
      body: ExcludeFocus(
        child: LayoutBuilder(builder: (context, c) {
          final s = uiScale(c.biggest);
          return Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                onTap: _onTap,
                onPanStart: _onPanStart,
                onPanUpdate: _onPanUpdate,
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: RunnerPainter(game, _repaint),
                    size: c.biggest,
                    isComplex: true,
                    willChange: true,
                  ),
                ),
              ),
              RepaintBoundary(
                child: AnimatedBuilder(
                  animation: _hud,
                  builder: (context, _) => _Hud(
                    game: game,
                    s: s,
                    size: c.biggest,
                    modeLabel: widget.modeLabel,
                    highscore: widget.progress.highscore(widget.modeKey),
                    newRecord: _newRecord,
                    result: _result,
                    onPause: _togglePause,
                    onContinue: _continue,
                    onRestart: _restart,
                    onExit: _exit,
                    onReview: _wrongQuestions.isNotEmpty && !_reviewDone ? _startReview : null,
                    onMute: () async {
                      await Sound.instance.toggleMute();
                      _hud.tick();
                    },
                    musicOn: widget.progress.musicOn,
                  ),
                ),
              ),
              if (widget.progress.showFps)
                Positioned(
                  left: 8,
                  bottom: 6,
                  child: IgnorePointer(
                    child: ValueListenableBuilder<double>(
                      valueListenable: QualityGovernor.instance.fps,
                      builder: (_, v, __) => Text(
                        '${v.round()} FPS · Grafik ${const ['niedrig', 'mittel', 'hoch'][RenderSettings.level]}',
                        style: const TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    ),
                  ),
                ),
            ],
          );
        }),
      ),
    ),
    );
  }
}

/// Ergebnis eines Laufs für den Abschlussbildschirm.
class RunResult {
  RunResult(this.xp, this.levelBefore, this.levelAfter, this.quests);
  final int xp;
  final int levelBefore;
  final int levelAfter;
  final List<Quest> quests;
}

class _Hud extends StatelessWidget {
  const _Hud({
    required this.game,
    required this.s,
    required this.size,
    required this.modeLabel,
    required this.highscore,
    required this.newRecord,
    required this.result,
    required this.onPause,
    required this.onContinue,
    required this.onRestart,
    required this.onExit,
    required this.onMute,
    required this.musicOn,
    required this.onReview,
  });

  final RunnerGame game;
  final double s;
  final Size size;
  final String modeLabel;
  final int highscore;
  final bool newRecord;
  final RunResult? result;
  final VoidCallback onMute;
  final bool musicOn;
  final VoidCallback? onReview;
  final VoidCallback onPause;
  final VoidCallback onContinue;
  final VoidCallback onRestart;
  final VoidCallback onExit;

  TextStyle _t(double size, {FontWeight w = FontWeight.w700, Color? c}) =>
      TextStyle(
        fontSize: size * s,
        fontWeight: w,
        color: c ?? Colors.white,
        shadows: const [Shadow(color: Colors.black87, offset: Offset(0, 1.5))],
      );

  @override
  Widget build(BuildContext context) {
    final g = game;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Links oben: Leben, Punkte, Münzen
        Positioned(
          left: 18 * s,
          top: 14 * s,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                for (var i = 0; i < max(g.lives, 3); i++)
                  Padding(
                    padding: EdgeInsets.only(right: 4 * s),
                    child: Icon(
                      i < g.lives ? Icons.favorite : Icons.favorite_border,
                      color: i < g.lives ? kBad : Colors.white38,
                      size: 30 * s,
                    ),
                  ),
              ]),
              SizedBox(height: 4 * s),
              Text('${g.score}', style: _t(34, w: FontWeight.w900)),
              Row(children: [
                Icon(Icons.monetization_on, color: kGold, size: 22 * s),
                SizedBox(width: 6 * s),
                Text('${g.coins}', style: _t(20, c: kGold)),
              ]),
              if (g.streak > 0) ...[
                SizedBox(height: 6 * s),
                Container(
                  padding:
                      EdgeInsets.symmetric(horizontal: 10 * s, vertical: 4 * s),
                  decoration: BoxDecoration(
                      color: kGood.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(20 * s),
                      border: Border.all(color: kGood)),
                  child: Text(
                      'Serie ${g.streak}  ·  x${g.multiplier.toStringAsFixed(2)}',
                      style: _t(14, c: kGood)),
                ),
              ],
              for (final e in g.powers.entries) ...[
                SizedBox(height: 6 * s),
                _powerChip(e.key, e.value),
              ],
            ],
          ),
        ),
        // Rechts oben: Distanz + Pause
        Positioned(
          right: 18 * s,
          top: 14 * s,
          child: Row(children: [
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('${g.distance.floor()} m', style: _t(24, w: FontWeight.w900)),
              Text(modeLabel, style: _t(13, c: Colors.white70)),
              Text('Rekord $highscore', style: _t(13, c: Colors.white70)),
            ]),
            SizedBox(width: 10 * s),
            IconButton.filledTonal(
              iconSize: 22 * s,
              tooltip: musicOn ? 'Musik aus' : 'Musik an',
              onPressed: onMute,
              icon: Icon(musicOn ? Icons.music_note : Icons.music_off),
            ),
            SizedBox(width: 6 * s),
            IconButton.filledTonal(
              iconSize: 26 * s,
              onPressed: onPause,
              icon: const Icon(Icons.pause),
            ),
          ]),
        ),
        if (g.activeGate != null &&
            (g.phase == Phase.running || g.phase == Phase.countdown))
          _questionPanel(g.activeGate!),
        if (g.toast != null && g.phase == Phase.running && g.activeGate == null)
          _toast(g.toast!),
        if (g.phase == Phase.countdown) _countdown(),
        if (g.phase == Phase.countdown || (g.phase == Phase.running && g.time < 6))
          _controlsHint(),
        if (g.phase == Phase.explaining && g.explaining != null)
          _explainOverlay(g.explaining!),
        if (g.phase == Phase.paused) _pauseOverlay(),
        if (g.phase == Phase.gameOver) _gameOverOverlay(),
      ],
    );
  }

  static const Map<PowerKind, IconData> _powerIcons = {
    PowerKind.magnet: Icons.attractions,
    PowerKind.shield: Icons.shield,
    PowerKind.doublePoints: Icons.looks_two,
    PowerKind.superJump: Icons.keyboard_double_arrow_up,
  };

  Widget _powerChip(PowerKind k, double left) {
    final col = Color(kPowerColors[k]!);
    final frac = (left / kPowerDuration[k]!).clamp(0.0, 1.0);
    return Container(
      width: 170 * s,
      padding: EdgeInsets.symmetric(horizontal: 8 * s, vertical: 5 * s),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(10 * s),
        border: Border.all(color: col.withValues(alpha: 0.8)),
      ),
      child: Row(children: [
        Icon(_powerIcons[k], color: col, size: 18 * s),
        SizedBox(width: 6 * s),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(kPowerNames[k]!, style: _t(12, c: col)),
            SizedBox(height: 3 * s),
            ClipRRect(
              borderRadius: BorderRadius.circular(3 * s),
              child: LinearProgressIndicator(
                value: frac,
                minHeight: 4 * s,
                color: col,
                backgroundColor: Colors.white12,
              ),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _questionPanel(Gate gate) {
    final q = gate.question;
    final dist = game.gateDistance ?? 0;
    final portrait = isPortrait(size);
    final width = portrait ? size.width - 16 : min(size.width - 40 * s, 980 * s);
    const letters = ['A', 'B', 'C'];
    const dirs = ['links', 'Mitte', 'rechts'];
    const colors = [Color(0xFF29B6F6), Color(0xFFAB47BC), Color(0xFF26A69A)];
    final myLane = (game.px / kLaneWidth).round().clamp(-1, 1) + 1;
    final longest = gate.answers.fold<int>(0, (m, a) => max(m, a.length));
    final answerFont = longest > 90 ? 13.5 : (longest > 44 ? 15.0 : 17.0);
    Widget answer(int i) => AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: double.infinity,
          padding: EdgeInsets.symmetric(horizontal: 10 * s, vertical: (portrait ? 6 : 8) * s),
          decoration: BoxDecoration(
            color: colors[i].withValues(alpha: myLane == i ? 0.45 : 0.16),
            borderRadius: BorderRadius.circular(12 * s),
            border: Border.all(color: colors[i], width: myLane == i ? 3 * s : 1.2 * s),
          ),
          child: portrait
              ? Row(children: [
                  Text('${letters[i]} ', style: _t(15, w: FontWeight.w900, c: colors[i])),
                  Expanded(
                      child: Text(gate.answers[i], style: _t(answerFont, w: FontWeight.w800))),
                ])
              : Column(children: [
                  Text('${letters[i]} · ${dirs[i]}', style: _t(12, c: Colors.white70)),
                  SizedBox(height: 2 * s),
                  Text(gate.answers[i],
                      textAlign: TextAlign.center, style: _t(answerFont, w: FontWeight.w800)),
                ]),
        );
    return Positioned(
      top: portrait ? 100 * s : 14 * s,
      left: (size.width - width) / 2,
      width: width,
      child: IgnorePointer(
        child: Panel(
          shadow: false,
          padding: EdgeInsets.fromLTRB(18 * s, 12 * s, 18 * s, 14 * s),
          radius: 18 * s,
          border: kAccent.withValues(alpha: 0.6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 8 * s, vertical: 2 * s),
                  decoration: BoxDecoration(
                      color: kAccent.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(8 * s)),
                  child: Text(
                      q.isCard ? 'Lernkarte ${q.bereich} · ${q.thema}' : '${q.pruefung} · ${q.thema}',
                      style: _t(12, c: kAccent)),
                ),
                const Spacer(),
                Text('Tor in ${dist.ceil()} m',
                    style: _t(13, c: dist < 25 ? kGold : Colors.white70)),
              ]),
              if (game.slowmo < 1) ...[
                SizedBox(height: 4 * s),
                game.answerLocked
                    ? Text('Antwort ${letters[myLane]} festgelegt – weiter geht’s!',
                        style: _t(13, c: kGood))
                    : Text(
                        isMobile || isWeb && portrait
                            ? 'Zeitlupe  ·  Spur wählen, dann TIPPEN zum Festlegen'
                            : 'Zeitlupe  ·  Spur wählen, dann LEERTASTE zum Festlegen',
                        style: _t(13, c: const Color(0xFFB388FF))),
              ],
              SizedBox(height: 6 * s),
              Text(q.frage,
                  textAlign: TextAlign.center,
                  style: _t(22, w: FontWeight.w800)),
              SizedBox(height: 10 * s),
              if (portrait)
                Column(children: [
                  for (var i = 0; i < 3; i++) ...[
                    if (i > 0) SizedBox(height: 6 * s),
                    answer(i),
                  ],
                ])
              else
                Row(
                  children: [
                    for (var i = 0; i < 3; i++) ...[
                      if (i > 0) SizedBox(width: 10 * s),
                      Expanded(child: answer(i)),
                    ],
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _toast(Toast t) {
    final width = min(size.width - 40 * s, 760 * s);
    final opacity = (t.time / 0.4).clamp(0.0, 1.0);
    return Positioned(
      top: 14 * s,
      left: (size.width - width) / 2,
      width: width,
      child: IgnorePointer(
        child: Opacity(
          opacity: opacity,
          child: Panel(
            shadow: false,
            padding: EdgeInsets.symmetric(horizontal: 18 * s, vertical: 12 * s),
            radius: 16 * s,
            border: t.positive ? kGood : kBad,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(t.title,
                  style: _t(26,
                      w: FontWeight.w900, c: t.positive ? kGood : kBad)),
              if (t.text.isNotEmpty) ...[
                SizedBox(height: 4 * s),
                Text(t.text, textAlign: TextAlign.center, style: _t(16)),
              ],
            ]),
          ),
        ),
      ),
    );
  }

  Widget _countdown() {
    final n = game.countdown.ceil().clamp(1, 3);
    return Center(
      child: IgnorePointer(
        child: Text('$n',
            style: _t(140, w: FontWeight.w900, c: Colors.white)
                .copyWith(shadows: const [
              Shadow(color: Colors.black, blurRadius: 24),
            ])),
      ),
    );
  }

  Widget _controlsHint() {
    final ks = 13.0 * s;
    Widget item(List<String> keys, String label) => Padding(
          padding: EdgeInsets.symmetric(horizontal: 10 * s),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            for (final k in keys) KeyCap(k, size: ks),
            SizedBox(width: 6 * s),
            Text(label, style: _t(14)),
          ]),
        );
    return Positioned(
      bottom: 18 * s,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: Center(
          child: Panel(
            shadow: false,
            padding: EdgeInsets.symmetric(horizontal: 12 * s, vertical: 10 * s),
            radius: 14 * s,
            child: Wrap(
              alignment: WrapAlignment.center,
              runSpacing: 6 * s,
              children: isMobile || isPortrait(size)
                  ? [
                      Text('Wischen: ← → Spur  ·  ↑ Springen  ·  ↓ Rollen  ·  Tippen: Antwort festlegen',
                          textAlign: TextAlign.center, style: _t(14)),
                    ]
                  : [
                item(['A', 'D', '←', '→'], 'Spur wechseln'),
                item(['W', '↑', 'Leertaste'], 'Springen'),
                item(['S', '↓'], 'Rollen'),
                item(['P', 'Esc'], 'Pause'),
                if (isDesktop) item(['F11'], 'Vollbild'),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _backdrop(Widget child) => Container(
        color: Colors.black.withValues(alpha: 0.62),
        alignment: Alignment.center,
        padding: EdgeInsets.all(20 * s),
        child: child,
      );

  Widget _explainOverlay(AnswerRecord rec) {
    final q = rec.question;
    return _backdrop(ConstrainedBox(
      constraints: BoxConstraints(maxWidth: 760 * s),
      child: Panel(
        padding: EdgeInsets.all(24 * s),
        radius: 20 * s,
        border: kBad,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.close_rounded, color: kBad, size: 34 * s),
              SizedBox(width: 8 * s),
              Text('Leider falsch  ·  −1 Leben',
                  style: _t(26, w: FontWeight.w900, c: kBad)),
            ]),
            SizedBox(height: 12 * s),
            Text(q.frage, style: _t(20, w: FontWeight.w800)),
            SizedBox(height: 12 * s),
            _answerLine('Deine Antwort', rec.chosen, kBad),
            SizedBox(height: 6 * s),
            _answerLine('Richtig ist', q.richtig, kGood),
            SizedBox(height: 14 * s),
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(12 * s),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(12 * s),
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.lightbulb_outline, color: kGold, size: 22 * s),
                SizedBox(width: 8 * s),
                Expanded(child: Text(q.erklaerung, style: _t(17, w: FontWeight.w500))),
              ]),
            ),
            SizedBox(height: 8 * s),
            Text('Die Frage kommt gleich nochmal dran.',
                style: _t(14, c: Colors.white60, w: FontWeight.w500)),
            SizedBox(height: 16 * s),
            Align(
              alignment: Alignment.centerRight,
              child: BigButton(
                label: game.lives > 0 ? 'Weiter' : 'Ergebnis',
                hint: 'Leertaste / Enter',
                icon: Icons.play_arrow_rounded,
                scale: s,
                onPressed: onContinue,
              ),
            ),
          ],
        ),
      ),
    ));
  }

  Widget _answerLine(String label, String text, Color c) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140 * s,
            child: Text(label, style: _t(15, c: Colors.white60, w: FontWeight.w600)),
          ),
          Expanded(child: Text(text, style: _t(17, c: c, w: FontWeight.w800))),
        ],
      );

  Widget _pauseOverlay() {
    return _backdrop(ConstrainedBox(
      constraints: BoxConstraints(maxWidth: 460 * s),
      child: Panel(
        padding: EdgeInsets.all(24 * s),
        radius: 20 * s,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Pause', style: _t(34, w: FontWeight.w900)),
          SizedBox(height: 18 * s),
          SizedBox(
            width: double.infinity,
            child: BigButton(
                label: 'Weiter',
                hint: 'Esc / P',
                icon: Icons.play_arrow_rounded,
                scale: s,
                onPressed: onPause),
          ),
          SizedBox(height: 10 * s),
          SizedBox(
            width: double.infinity,
            child: BigButton(
                label: 'Neu starten',
                icon: Icons.replay,
                color: Colors.white70,
                scale: s,
                onPressed: onRestart),
          ),
          SizedBox(height: 10 * s),
          SizedBox(
            width: double.infinity,
            child: BigButton(
                label: 'Hauptmenü',
                hint: 'M',
                icon: Icons.home_rounded,
                color: Colors.white70,
                scale: s,
                onPressed: onExit),
          ),
          SizedBox(height: 10 * s),
          SizedBox(
            width: double.infinity,
            child: BigButton(
                label: musicOn ? 'Musik aus' : 'Musik an',
                icon: musicOn ? Icons.music_off : Icons.music_note,
                color: Colors.white38,
                scale: s,
                onPressed: onMute),
          ),
          SizedBox(height: 10 * s),
          SizedBox(
            width: double.infinity,
            child: BigButton(
                label: 'Vollbild an/aus',
                hint: 'F11',
                icon: Icons.fullscreen,
                color: Colors.white38,
                scale: s,
                onPressed: AppWindow.toggleFullscreen),
          ),
        ]),
      ),
    ));
  }

  Widget _resultLine(RunResult r) {
    final up = r.levelAfter > r.levelBefore;
    return Column(children: [
      Wrap(
        alignment: WrapAlignment.center,
        spacing: 10 * s,
        runSpacing: 6 * s,
        children: [
          _pill(Icons.auto_awesome, '+${r.xp} XP', const Color(0xFFB388FF)),
          if (up)
            _pill(Icons.trending_up, 'Level ${r.levelAfter} erreicht!', kGold)
          else
            _pill(Icons.military_tech, 'Level ${r.levelAfter}', Colors.white70),
          if (up && chapterForLevel(r.levelAfter) != chapterForLevel(r.levelBefore))
            _pill(Icons.menu_book, 'Neues Kapitel: ${chapterForLevel(r.levelAfter).title}',
                kAccent),
        ],
      ),
      for (final q in r.quests) ...[
        SizedBox(height: 6 * s),
        _pill(Icons.check_circle, 'Quest erledigt: ${q.text}  (im Menü abholen)', kGood),
      ],
    ]);
  }

  Widget _pill(IconData icon, String text, Color c) => Container(
        padding: EdgeInsets.symmetric(horizontal: 12 * s, vertical: 6 * s),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(20 * s),
          border: Border.all(color: c.withValues(alpha: 0.7)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: c, size: 18 * s),
          SizedBox(width: 6 * s),
          Flexible(child: Text(text, style: _t(14, c: c))),
        ]),
      );

  Widget _gameOverOverlay() {
    final g = game;
    final total = g.correctCount + g.wrongCount;
    final wrong = <Question>[];
    for (final a in g.answers) {
      if (!a.correct && !wrong.contains(a.question)) wrong.add(a.question);
    }
    Widget stat(String label, String value, {Color? c}) => Expanded(
          child: Column(children: [
            Text(value, style: _t(26, w: FontWeight.w900, c: c)),
            Text(label, style: _t(13, c: Colors.white60, w: FontWeight.w500)),
          ]),
        );
    return _backdrop(ConstrainedBox(
      constraints: BoxConstraints(maxWidth: 820 * s, maxHeight: size.height * 0.92),
      child: Panel(
        padding: EdgeInsets.all(24 * s),
        radius: 20 * s,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Lauf beendet', style: _t(34, w: FontWeight.w900)),
          if (newRecord)
            Padding(
              padding: EdgeInsets.only(top: 4 * s),
              child: Text('Neuer Rekord!', style: _t(20, c: kGold, w: FontWeight.w900)),
            ),
          SizedBox(height: 16 * s),
          Row(children: [
            stat('Punkte', '${g.score}', c: kAccent),
            stat('Richtig', '${g.correctCount}/$total', c: kGood),
            stat('Beste Serie', '${g.bestStreak}'),
            stat('Münzen', '${g.coins}', c: kGold),
            stat('Strecke', '${g.distance.floor()} m'),
          ]),
          if (result != null) ...[
            SizedBox(height: 12 * s),
            _resultLine(result!),
          ],
          SizedBox(height: 16 * s),
          if (wrong.isNotEmpty && onReview != null) ...[
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(14 * s),
              decoration: BoxDecoration(
                color: kGood.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(14 * s),
                border: Border.all(color: kGood.withValues(alpha: 0.5)),
              ),
              child: Row(children: [
                Icon(Icons.school, color: kGood, size: 34 * s),
                SizedBox(width: 12 * s),
                Expanded(
                  child: Text(
                      'Abschlusstest: ${wrong.length} ${wrong.length == 1 ? 'Frage' : 'Fragen'} aus diesem Lauf. '
                      'Richtig beantwortet = gelernt, sie kommen im Lauf nicht mehr.',
                      style: _t(15, w: FontWeight.w600)),
                ),
                SizedBox(width: 12 * s),
                BigButton(
                  label: 'Test starten',
                  hint: 'Enter',
                  icon: Icons.quiz,
                  color: kGood,
                  scale: s,
                  onPressed: onReview!,
                ),
              ]),
            ),
            SizedBox(height: 12 * s),
          ],
          if (wrong.isNotEmpty) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: Text('Das solltest du wiederholen:',
                  style: _t(17, w: FontWeight.w800)),
            ),
            SizedBox(height: 8 * s),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final q in wrong)
                    Container(
                      margin: EdgeInsets.only(bottom: 8 * s),
                      padding: EdgeInsets.all(12 * s),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(12 * s),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(q.frage, style: _t(16, w: FontWeight.w700)),
                          SizedBox(height: 4 * s),
                          Text('✓ ${q.richtig}', style: _t(16, c: kGood)),
                          SizedBox(height: 2 * s),
                          Text(q.erklaerung,
                              style: _t(14, c: Colors.white70, w: FontWeight.w500)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ] else if (total > 0)
            Text('Alle Fragen richtig. Stark!',
                style: _t(18, c: kGood, w: FontWeight.w800)),
          SizedBox(height: 16 * s),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            BigButton(
                label: 'Hauptmenü',
                hint: 'Esc',
                icon: Icons.home_rounded,
                color: Colors.white70,
                scale: s,
                onPressed: onExit),
            SizedBox(width: 12 * s),
            BigButton(
                label: 'Nochmal',
                hint: onReview != null && wrong.isNotEmpty ? null : 'Enter',
                icon: Icons.replay,
                scale: s,
                onPressed: onRestart),
          ]),
        ]),
      ),
    ));
  }
}
