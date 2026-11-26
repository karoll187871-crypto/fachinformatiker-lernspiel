import 'dart:math';

import '../data/cosmetics.dart';
import '../data/question_bank.dart';
import '../data/quests.dart';

/// Welt-Einheiten: 1 Einheit ≈ 1 Meter.
/// x = seitlich (Spur -1, 0, 1), y = Höhe, z = nach vorne (Laufrichtung).
const double kLaneWidth = 2.2;
const double kGravity = 44;
const double kJumpVelocity = 14.5; // Sprunghöhe ≈ 2,4 m, Flugzeit ≈ 0,66 s
const double kRollTime = 0.62;
const double kPlayerHeight = 1.8;
const double kRollHeight = 0.9;

enum Phase { countdown, running, paused, explaining, gameOver }

enum ObstacleKind { low, high, train }

enum PowerKind { magnet, shield, doublePoints, superJump }

/// Soundeffekte, die das Spiel auslöst.
enum Sfx { coin, jump, roll, correct, wrong, crash, powerup, shield }

const Map<PowerKind, String> kPowerNames = {
  PowerKind.magnet: 'Münzmagnet',
  PowerKind.shield: 'Schutzschild',
  PowerKind.doublePoints: '2× Punkte',
  PowerKind.superJump: 'Super-Sprung',
};

const Map<PowerKind, int> kPowerColors = {
  PowerKind.magnet: 0xFFFF5252,
  PowerKind.shield: 0xFF40C4FF,
  PowerKind.doublePoints: 0xFFFFD740,
  PowerKind.superJump: 0xFF69F0AE,
};

const Map<PowerKind, double> kPowerDuration = {
  PowerKind.magnet: 9,
  PowerKind.shield: 20,
  PowerKind.doublePoints: 10,
  PowerKind.superJump: 9,
};

enum Tempo {
  entspannt('Entspannt', 11, 21, 1.35, crashCostsLife: false),
  normal('Normal', 13, 26, 1.0),
  schnell('Schnell', 16, 32, 0.8);

  const Tempo(this.label, this.startSpeed, this.maxSpeed, this.readFactor,
      {this.crashCostsLife = true});
  final String label;
  final bool crashCostsLife; // Entspannt: Unfälle kosten kein Leben
  final double startSpeed;
  final double maxSpeed;
  final double readFactor;

  static Tempo byName(String n) =>
      values.firstWhere((t) => t.name == n, orElse: () => Tempo.normal);
}

class Obstacle {
  Obstacle(this.kind, this.lane, this.wz, this.length, this.style);
  final ObstacleKind kind;
  final int lane;
  final double wz; // Weltposition der Vorderkante
  final double length;
  final int style;
  bool hit = false;
  bool passed = false; // für Quests (drunter durch / drüber gesprungen)
}

class PowerItem {
  PowerItem(this.kind, this.lane, this.wz);
  final PowerKind kind;
  final int lane;
  final double wz;
  bool taken = false;
}

class Coin {
  Coin(this.lane, this.wz, this.y);
  final int lane;
  final double wz;
  final double y;
  bool taken = false;
}

class Gate {
  Gate(this.question, this.answers, this.correctIndex, this.wz);
  final Question question;
  final List<String> answers; // Index 0 = links, 1 = Mitte, 2 = rechts
  final int correctIndex;
  final double wz;
  int? chosen;

  /// Vom Renderer genutzter Cache (vorbereitete Texte).
  Object? renderCache;
}

class Particle {
  Particle(this.x, this.y, this.wz, this.vx, this.vy, this.vz, this.life,
      this.color, this.size)
      : maxLife = life;
  double x, y, wz, vx, vy, vz, life;
  final double maxLife;
  final int color;
  final double size;
}

class AnswerRecord {
  AnswerRecord(this.question, this.chosen, {required this.correct});
  final Question question;
  final String chosen;
  final bool correct;
}

class Toast {
  Toast(this.title, this.text, {required this.positive, this.time = 3.5});
  final String title;
  final String text;
  final bool positive;
  double time;
}

class RunnerGame {
  RunnerGame({
    this.deck,
    this.tempo = Tempo.normal,
    this.demo = false,
    this.onAnswer,
    this.onGameOver,
    this.onSound,
    this.look = const PlayerLook(hoodie: 0xFF1E88E5, pants: 0xFF263238),
    this.trailColors = const [],
    this.slowmo = 1.0,
    int? seed,
  }) : rng = Random(seed) {
    speed = tempo.startSpeed;
    if (demo) {
      phase = Phase.running;
      _nextQuestionAt = double.infinity;
    }
  }

  final QuestionDeck? deck;
  final Tempo tempo;
  final bool demo;
  final void Function(Question q, bool correct)? onAnswer;
  final void Function()? onGameOver;
  final void Function(Sfx s)? onSound;
  final PlayerLook look;
  final List<int> trailColors;

  /// Zeitlupe während einer Frage (1.0 = aus, 0.5 = halbe Geschwindigkeit).
  final double slowmo;

  /// Spieler hat seine Antwort mit Leertaste festgelegt (Zeitlupe vorbei).
  bool answerLocked = false;
  double _timeScale = 1;
  double get timeScale => _timeScale;

  /// Zeitlupe gerade aktiv (oder im Übergang)?
  bool get slowmoActive =>
      slowmo < 1 && activeGate != null && !answerLocked && phase == Phase.running;

  final Random rng;
  final RunStats stats = RunStats();

  /// Aktive Power-ups und ihre Restzeit in Sekunden.
  final Map<PowerKind, double> powers = {};
  bool has(PowerKind k) => (powers[k] ?? 0) > 0;

  Phase phase = Phase.countdown;
  double countdown = 3.0;
  double time = 0;
  double distance = 0;
  double speed = 0;
  double _scoreAcc = 0;
  int bonus = 0;
  int coins = 0;
  int lives = 3;
  static const int maxLives = 5;
  int streak = 0;
  int bestStreak = 0;
  int correctCount = 0;
  int wrongCount = 0;
  double shake = 0;

  // Spieler
  int lane = 0;
  double px = 0, py = 0, vy = 0;
  double rollTimer = 0, invuln = 0, stumble = 0, runPhase = 0;
  double lean = 0;
  double _jumpBuffer = 0;
  bool _fastFall = false;

  bool get rolling => rollTimer > 0;
  bool get airborne => py > 0.001 || vy > 0;
  int get score => _scoreAcc.floor() + bonus;
  double get multiplier =>
      (1 + min(streak, 8) * 0.25) * (has(PowerKind.doublePoints) ? 2 : 1);

  final List<Obstacle> obstacles = [];
  final List<Coin> coinItems = [];
  final List<PowerItem> powerItems = [];
  final List<Gate> gates = [];
  final List<Particle> particles = [];
  final List<AnswerRecord> answers = [];

  Gate? activeGate;
  Toast? toast;
  AnswerRecord? explaining;

  double _spawnCursor = 45;
  double _nextQuestionAt = 30;
  double _coinsOnlyUntil = -1;
  double _demoTimer = 0;
  double _fxTimer = 0;

  /// Abstand zum aktiven Tor in Metern (oder null).
  double? get gateDistance =>
      activeGate == null ? null : max(0, activeGate!.wz - distance);

  // ---------------------------------------------------------------- Steuerung

  // Eingaben werden nie verschluckt (auch nicht nach einem Unfall).
  bool get _canControl => phase == Phase.running;

  /// Antwort festlegen: Zeitlupe endet, Spur bleibt bis zum Tor fest.
  bool confirmAnswer() {
    if (!slowmoActive) return false;
    answerLocked = true;
    return true;
  }

  bool get _laneLocked => answerLocked && activeGate != null;

  void moveLeft() {
    if (!_canControl || lane <= -1 || _laneLocked) return;
    lane--;
  }

  void moveRight() {
    if (!_canControl || lane >= 1 || _laneLocked) return;
    lane++;
  }

  void jump() {
    if (!_canControl) return;
    if (!airborne) {
      _doJump();
    } else {
      _jumpBuffer = 0.15; // Sprung kurz vor der Landung wird gemerkt
    }
  }

  void _doJump() {
    vy = kJumpVelocity * (has(PowerKind.superJump) ? 1.45 : 1.0);
    rollTimer = 0;
    _fastFall = false;
    _jumpBuffer = 0;
    if (!demo) onSound?.call(Sfx.jump);
  }

  void roll() {
    if (!_canControl) return;
    if (airborne) {
      _fastFall = true; // schnell runter, dann rollen
      vy = min(vy, -6);
    } else {
      if (rollTimer <= 0) onSound?.call(Sfx.roll);
      rollTimer = kRollTime;
    }
  }

  void togglePause() {
    if (phase == Phase.running) {
      phase = Phase.paused;
    } else if (phase == Phase.paused) {
      phase = Phase.running;
    }
  }

  void continueAfterExplanation() {
    if (phase != Phase.explaining) return;
    explaining = null;
    if (lives <= 0) {
      _gameOver();
    } else {
      phase = Phase.running;
      invuln = max(invuln, 1.0);
    }
  }

  // ----------------------------------------------------------------- Update

  void update(double dt) {
    if (phase == Phase.paused || phase == Phase.explaining) return;
    _updateParticles(dt);
    if (toast != null) {
      toast!.time -= dt;
      if (toast!.time <= 0) toast = null;
    }
    shake = max(0, shake - dt * 1.6);
    if (phase == Phase.gameOver) return;
    if (phase == Phase.countdown) {
      countdown -= dt;
      runPhase += dt * 4;
      if (countdown <= 0) phase = Phase.running;
      return;
    }

    // Zeitlupe weich ein- und ausblenden (in Echtzeit)
    final targetScale = slowmoActive ? slowmo : 1.0;
    _timeScale += (targetScale - _timeScale) * min(1, dt * 7);
    dt *= _timeScale;

    time += dt;
    final ramp = 1 - exp(-time / 140);
    var target = tempo.startSpeed + (tempo.maxSpeed - tempo.startSpeed) * ramp;
    if (activeGate != null) target *= 0.82; // etwas langsamer zum Lesen
    if (stumble > 0) target *= 0.55;
    speed += (target - speed) * min(1, dt * 1.8);

    final prevDistance = distance;
    final dz = speed * dt;
    distance += dz;
    _scoreAcc += dz * 0.5 * multiplier;
    runPhase += dt * (4 + speed * 0.42);

    // Seitlich
    final tx = lane * kLaneWidth;
    final prevX = px;
    px += (tx - px) * min(1, dt * 16);
    lean += (((px - prevX) / max(dt, 1e-4)) * 0.035 - lean) * min(1, dt * 10);

    // Vertikal
    if (airborne) {
      vy -= kGravity * dt * (_fastFall ? 2.6 : 1.0);
      py += vy * dt;
      if (py <= 0) {
        py = 0;
        vy = 0;
        if (_fastFall) {
          _fastFall = false;
          rollTimer = kRollTime;
          onSound?.call(Sfx.roll);
        } else if (_jumpBuffer > 0) {
          _doJump();
        }
      }
    }
    if (_jumpBuffer > 0) _jumpBuffer -= dt;
    if (rollTimer > 0) rollTimer -= dt;
    if (invuln > 0) invuln -= dt;
    if (stumble > 0) stumble -= dt;
    for (final k in powers.keys.toList()) {
      final left = powers[k]! - dt;
      if (left <= 0) {
        powers.remove(k);
      } else {
        powers[k] = left;
      }
    }
    _effects(dt);

    if (demo) _demoPilot(dt);

    _scheduleQuestion();
    _spawn();
    _collide(prevDistance);
    _collectCoins(prevDistance);
    _collectPowers(prevDistance);
    _checkGates();
    _cleanup();
  }

  void _demoPilot(double dt) {
    _demoTimer -= dt;
    if (_demoTimer <= 0) {
      _demoTimer = 1.2 + rng.nextDouble() * 1.8;
      final r = rng.nextDouble();
      if (r < 0.35) {
        lane = (lane + (rng.nextBool() ? 1 : -1)).clamp(-1, 1);
      } else if (r < 0.55 && !airborne) {
        _doJump();
      }
    }
  }

  /// Staub beim Rollen und die gekaufte Laufspur.
  void _effects(double dt) {
    _fxTimer -= dt;
    if (_fxTimer > 0) return;
    _fxTimer = 0.035;
    if (rolling && !airborne) {
      for (var i = 0; i < 2; i++) {
        particles.add(Particle(
            px + (rng.nextDouble() - 0.5) * 0.8,
            0.12,
            distance - 0.2,
            (rng.nextDouble() - 0.5) * 2,
            1 + rng.nextDouble() * 1.5,
            speed * 0.6 - 2 - rng.nextDouble() * 2,
            0.35,
            0xFFB0A090,
            0.09 + rng.nextDouble() * 0.06));
      }
    }
    if (trailColors.isNotEmpty && phase == Phase.running) {
      final c = trailColors[rng.nextInt(trailColors.length)];
      particles.add(Particle(
          px + (rng.nextDouble() - 0.5) * 0.5,
          py + 0.4 + rng.nextDouble() * 0.8,
          distance - 0.4,
          (rng.nextDouble() - 0.5) * 0.6,
          0.3 + rng.nextDouble(),
          speed * 0.75,
          0.55,
          c,
          0.06 + rng.nextDouble() * 0.05));
    }
  }

  // ---------------------------------------------------------------- Spawning

  void _scheduleQuestion() {
    if (demo || deck == null || activeGate != null) return;
    if (distance < _nextQuestionAt) return;

    final q = deck!.next();
    final wrong = [...q.falsch]..shuffle(rng);
    final options = [q.richtig, wrong[0], wrong[1]]..shuffle(rng);
    final correctIndex = options.indexOf(q.richtig);

    // Hindernisse weiter vorne entfernen: freie Strecke zum Lesen.
    const keep = 55.0;
    obstacles.removeWhere((o) => o.wz > distance + keep);
    coinItems.removeWhere((c) => c.wz > distance + keep);
    powerItems.removeWhere((p) => p.wz > distance + keep);
    _spawnCursor = min(_spawnCursor, distance + keep);

    final readSeconds =
        (6.5 + (q.frage.length + options.join().length) / 38) * tempo.readFactor;
    final gateWz = distance + max(85.0, speed * 0.82 * readSeconds.clamp(7.0, 17.0));
    final gate = Gate(q, options, correctIndex, gateWz);
    gates.add(gate);
    activeGate = gate;
    answerLocked = false;
    _coinsOnlyUntil = gateWz + 22;
  }

  void _spawn() {
    const viewAhead = 160.0;
    while (_spawnCursor < distance + viewAhead) {
      final gap = speed.clamp(12.0, 32.0) * (0.95 + rng.nextDouble() * 0.55);
      if (demo || _spawnCursor < _coinsOnlyUntil) {
        final g = activeGate;
        final nearGate = g != null && (_spawnCursor - g.wz).abs() < 14;
        if (!nearGate && rng.nextDouble() < 0.7) {
          _coinLine(rng.nextInt(3) - 1, _spawnCursor, 6);
        }
        _spawnCursor += gap * 0.9;
        continue;
      }
      final extra = _spawnRow(_spawnCursor);
      _spawnCursor += gap + extra;
    }
  }

  int _randLane() => rng.nextInt(3) - 1;

  void _coinLine(int lane, double wz, int count, {bool arc = false}) {
    if (!demo && !arc && time > 8 && rng.nextDouble() < 0.09) {
      final kind = PowerKind.values[rng.nextInt(PowerKind.values.length)];
      powerItems.add(PowerItem(kind, lane, wz + 3));
      count = max(2, count - 3);
      wz += 8;
    }
    for (var i = 0; i < count; i++) {
      final t = count == 1 ? 0.5 : i / (count - 1);
      final y = arc ? 1.0 + sin(t * pi) * 1.7 : 0.9;
      coinItems.add(Coin(lane, wz + i * 2.0 - (arc ? 4.0 : 0), y));
    }
  }

  double _train(int lane, double wz) {
    final len = 9.0 + rng.nextDouble() * 9.0;
    obstacles.add(Obstacle(ObstacleKind.train, lane, wz, len, rng.nextInt(4)));
    return len;
  }

  void _barrier(ObstacleKind kind, int lane, double wz) {
    obstacles.add(Obstacle(kind, lane, wz, 0.35, rng.nextInt(4)));
  }

  /// Erzeugt eine Hindernisreihe. Es bleibt immer ein machbarer Weg.
  double _spawnRow(double wz) {
    final difficulty = (time / 160).clamp(0.0, 1.0);
    final r = rng.nextDouble();
    var extra = 0.0;
    if (r < 0.26) {
      final l = _randLane();
      final k = rng.nextDouble();
      if (k < 0.38) {
        extra = _train(l, wz);
      } else {
        _barrier(k < 0.7 ? ObstacleKind.low : ObstacleKind.high, l, wz);
        if (k < 0.7) _coinLine(l, wz, 5, arc: true);
      }
      final other = (l + 1 + rng.nextInt(2) + 1) % 3 - 1;
      _coinLine(other, wz, 6);
    } else if (r < 0.44) {
      final free = _randLane();
      for (final l in [-1, 0, 1]) {
        if (l == free) continue;
        extra = max(extra, _train(l, wz));
      }
      _coinLine(free, wz, 7);
    } else if (r < 0.44 + 0.12 + difficulty * 0.08) {
      final kind = rng.nextBool() ? ObstacleKind.low : ObstacleKind.high;
      for (final l in [-1, 0, 1]) {
        _barrier(kind, l, wz);
      }
    } else if (r < 0.80) {
      final lanes = [-1, 0, 1]..shuffle(rng);
      extra = _train(lanes[0], wz);
      _barrier(rng.nextBool() ? ObstacleKind.low : ObstacleKind.high,
          lanes[1], wz + 2);
      _coinLine(lanes[2], wz, 6);
    } else if (r < 0.92) {
      final l = _randLane();
      _barrier(ObstacleKind.low, l, wz);
      _coinLine(l, wz, 5, arc: true);
    } else {
      _coinLine(_randLane(), wz, 8);
    }
    return extra;
  }

  // -------------------------------------------------------------- Kollision

  bool _inLane(int lane, double tolerance) =>
      (px - lane * kLaneWidth).abs() < tolerance;

  void _collide(double prevDistance) {
    if (demo) return;
    final pMin = prevDistance - 0.3;
    final pMax = distance + 0.3;
    for (final o in obstacles) {
      if (o.hit) continue;
      if (o.wz > pMax || o.wz + o.length < pMin) continue;
      if (!_inLane(o.lane, 1.15)) continue;
      final height = rolling ? kRollHeight : kPlayerHeight;
      final bool hit;
      switch (o.kind) {
        case ObstacleKind.low:
          hit = py < 0.95;
        case ObstacleKind.high:
          hit = py + height > 1.3 && py < 2.4;
        case ObstacleKind.train:
          hit = py < 3.3; // nur mit Super-Sprung drüber
      }
      if (hit) {
        _crash(o);
      } else if (!o.passed && o.kind != ObstacleKind.train) {
        o.passed = true;
        if (o.kind == ObstacleKind.high) {
          stats.rollUnders++;
        } else {
          stats.jumpOvers++;
        }
      }
    }
  }

  void _crash(Obstacle o) {
    if (invuln > 0) return;
    o.hit = true;
    if (has(PowerKind.shield)) {
      powers.remove(PowerKind.shield);
      invuln = 1.2;
      shake = 0.3;
      _burst(px, 1.0, distance + 0.5, 0xFF40C4FF, 26, spread: 5);
      onSound?.call(Sfx.shield);
      return;
    }
    onSound?.call(Sfx.crash);
    if (o.kind == ObstacleKind.train) _escapeTrain();
    if (tempo.crashCostsLife) lives--;
    invuln = 2.0;
    stumble = 0.45;
    shake = 0.6;
    speed *= 0.5;
    _burst(px, 1.0, distance + 0.5, 0xFFFF5252, 22);
    if (activeGate == null) {
      toast = Toast(
          'Autsch!',
          tempo.crashCostsLife
              ? (lives > 0 ? 'Noch $lives Leben' : '')
              : 'Kein Leben verloren (Entspannt)',
          positive: false,
          time: 1.3);
    }
    if (lives <= 0) _gameOver();
  }

  /// Nach einem Zug-Unfall auf eine freie Spur ausweichen, damit die
  /// Figur (und die Kamera) nicht im Zug steckt.
  void _escapeTrain() {
    bool blocked(int l) => obstacles.any((t) =>
        t.kind == ObstacleKind.train &&
        t.lane == l &&
        t.wz - 2 < distance + 1 &&
        t.wz + t.length > distance - 1);
    for (final l in [lane - 1, lane + 1, lane - 2, lane + 2]) {
      if (l >= -1 && l <= 1 && !blocked(l)) {
        lane = l;
        return;
      }
    }
  }

  void _collectCoins(double prevDistance) {
    final magnet = has(PowerKind.magnet);
    final pMin = prevDistance - 0.6;
    final pMax = distance + (magnet ? 9 : 0.6);
    final height = rolling ? kRollHeight : kPlayerHeight;
    var got = false;
    for (final c in coinItems) {
      if (c.taken || c.wz < pMin || c.wz > pMax) continue;
      if (!magnet) {
        if (!_inLane(c.lane, 0.95)) continue;
        if (c.y < py - 0.3 || c.y > py + height + 0.3) continue;
      }
      c.taken = true;
      final v = has(PowerKind.doublePoints) ? 2 : 1;
      coins += v;
      if (!demo) stats.coins += v;
      bonus += 5 * v;
      got = true;
      _burst(c.lane * kLaneWidth, c.y, c.wz, 0xFFFFD54F, 5, spread: 2.5);
    }
    if (got && !demo) onSound?.call(Sfx.coin);
  }

  void _collectPowers(double prevDistance) {
    final pMin = prevDistance - 0.8;
    final pMax = distance + 0.8;
    for (final p in powerItems) {
      if (p.taken || p.wz < pMin || p.wz > pMax) continue;
      if (!_inLane(p.lane, 1.0)) continue;
      if (py > 2.6) continue;
      p.taken = true;
      powers[p.kind] = kPowerDuration[p.kind]!;
      stats.powerUps++;
      onSound?.call(Sfx.powerup);
      _burst(p.lane * kLaneWidth, 1.2, p.wz, kPowerColors[p.kind]!, 24, spread: 5);
      if (activeGate == null) {
        toast = Toast(kPowerNames[p.kind]!, _powerHint(p.kind),
            positive: true, time: 1.6);
      }
    }
  }

  static String _powerHint(PowerKind k) => switch (k) {
        PowerKind.magnet => 'Münzen fliegen zu dir',
        PowerKind.shield => 'Ein Unfall ist frei',
        PowerKind.doublePoints => 'Punkte und Münzen doppelt',
        PowerKind.superJump => 'Spring sogar über Züge',
      };

  void _checkGates() {
    final g = activeGate;
    if (g == null || g.chosen != null) return;
    if (g.wz > distance) return;
    final chosen = (px / kLaneWidth).round().clamp(-1, 1) + 1;
    g.chosen = chosen;
    activeGate = null;
    answerLocked = false;
    _nextQuestionAt = distance + speed * (7 + rng.nextDouble() * 4);
    final ok = chosen == g.correctIndex;
    answers.add(AnswerRecord(g.question, g.answers[chosen], correct: ok));
    onAnswer?.call(g.question, ok);
    onSound?.call(ok ? Sfx.correct : Sfx.wrong);
    if (ok) {
      correctCount++;
      final pts = (250 * multiplier).round();
      streak++;
      bestStreak = max(bestStreak, streak);
      bonus += pts;
      coins += 5;
      final xpGain = 20 + 5 * min<int>(streak - 1, 6);
      final q = g.question;
      stats
        ..correct += 1
        ..coins += 5
        ..xp += xpGain
        ..bestStreak = bestStreak;
      stats.correctByTopic[q.thema] = (stats.correctByTopic[q.thema] ?? 0) + 1;
      stats.correctByExam[q.pruefung] = (stats.correctByExam[q.pruefung] ?? 0) + 1;
      var title = 'Richtig! +$pts  ·  +$xpGain XP';
      if (streak % 3 == 0 && lives < maxLives) {
        lives++;
        title += '  ·  +1 Leben';
      }
      toast = Toast(title, g.question.erklaerung, positive: true, time: 4.0);
      for (var i = 0; i < 3; i++) {
        _burst(px, 1.2 + i * 0.6, distance + 2, 0xFF69F0AE, 12, spread: 5);
      }
    } else {
      wrongCount++;
      stats
        ..wrong += 1
        ..xp += 5; // auch aus Fehlern lernt man
      streak = 0;
      lives--;
      deck?.requeue(g.question);
      _burst(px, 1.2, distance + 2, 0xFFFF5252, 20, spread: 4);
      explaining = answers.last;
      phase = Phase.explaining;
      toast = null;
    }
  }

  void _gameOver() {
    if (phase == Phase.gameOver) return;
    stats
      ..distance = distance.floor()
      ..xp += distance ~/ 100;
    phase = Phase.gameOver;
    onGameOver?.call();
  }

  void _cleanup() {
    final minWz = distance - 12;
    obstacles.removeWhere((o) => o.wz + o.length < minWz);
    coinItems.removeWhere((c) => c.wz < minWz || (c.taken && c.wz < distance));
    gates.removeWhere((g) => g.wz < minWz);
    powerItems.removeWhere((p) => p.wz < minWz || p.taken);
  }

  // -------------------------------------------------------------- Partikel

  void _burst(double x, double y, double wz, int color, int n,
      {double spread = 6}) {
    for (var i = 0; i < n; i++) {
      final a = rng.nextDouble() * pi * 2;
      final s = spread * (0.4 + rng.nextDouble());
      particles.add(Particle(
        x,
        y,
        wz,
        cos(a) * s,
        2 + rng.nextDouble() * spread,
        sin(a) * s + speed * 0.6,
        0.5 + rng.nextDouble() * 0.5,
        color,
        0.07 + rng.nextDouble() * 0.08,
      ));
    }
  }

  void _updateParticles(double dt) {
    for (final p in particles) {
      p.life -= dt;
      p.vy -= 14 * dt;
      p.x += p.vx * dt;
      p.y += p.vy * dt;
      p.wz += p.vz * dt;
    }
    particles.removeWhere((p) => p.life <= 0);
  }
}
