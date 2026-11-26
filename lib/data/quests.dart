import 'dart:math';

/// Statistik eines einzelnen Laufs (für Quests und XP).
class RunStats {
  int correct = 0;
  int wrong = 0;
  int coins = 0;
  int distance = 0;
  int bestStreak = 0;
  int rollUnders = 0;
  int jumpOvers = 0;
  int powerUps = 0;
  int xp = 0;
  final Map<String, int> correctByTopic = {};
  final Map<String, int> correctByExam = {};
}

enum QuestKind { correct, topic, exam, streak, coins, distance, rollUnder, jumpOver, powerUps }

class Quest {
  Quest(this.kind, this.target, this.reward, this.xp, {this.param = '', this.progress = 0, this.claimed = false});

  final QuestKind kind;
  final int target;
  final int reward;
  final int xp;
  final String param; // Thema oder Prüfung
  int progress;
  bool claimed;

  bool get done => progress >= target;

  String get text => switch (kind) {
        QuestKind.correct => 'Beantworte $target Fragen richtig',
        QuestKind.topic => '$target× richtig im Thema „$param“',
        QuestKind.exam => 'Beantworte $target $param-Fragen richtig',
        QuestKind.streak => 'Schaffe eine Serie von $target richtigen Antworten',
        QuestKind.coins => 'Sammle $target Münzen',
        QuestKind.distance => 'Lauf $target m in einem Lauf',
        QuestKind.rollUnder => 'Roll $target× unter Schranken durch',
        QuestKind.jumpOver => 'Spring $target× über Absperrungen',
        QuestKind.powerUps => 'Sammle $target Power-ups',
      };

  /// Fortschritt aus einem Lauf übernehmen. Gibt true zurück,
  /// wenn die Quest dadurch gerade fertig wurde.
  bool apply(RunStats s) {
    if (done) return false;
    final add = switch (kind) {
      QuestKind.correct => s.correct,
      QuestKind.topic => s.correctByTopic[param] ?? 0,
      QuestKind.exam => s.correctByExam[param] ?? 0,
      QuestKind.coins => s.coins,
      QuestKind.rollUnder => s.rollUnders,
      QuestKind.jumpOver => s.jumpOvers,
      QuestKind.powerUps => s.powerUps,
      QuestKind.streak || QuestKind.distance => 0,
    };
    if (kind == QuestKind.streak) {
      progress = max(progress, s.bestStreak);
    } else if (kind == QuestKind.distance) {
      progress = max(progress, s.distance);
    } else {
      progress += add;
    }
    progress = min(progress, target);
    return done;
  }

  Map<String, dynamic> toJson() => {
        'k': kind.name,
        't': target,
        'r': reward,
        'x': xp,
        'p': param,
        'g': progress,
        'c': claimed,
      };

  static Quest fromJson(Map<String, dynamic> j) => Quest(
        QuestKind.values.byName(j['k'] as String),
        j['t'] as int,
        j['r'] as int,
        j['x'] as int,
        param: j['p'] as String? ?? '',
        progress: j['g'] as int? ?? 0,
        claimed: j['c'] as bool? ?? false,
      );
}

/// Drei Tagesquests, davon mindestens zwei mit Prüfungsbezug.
List<Quest> generateQuests(Random rng, List<String> topics) {
  final learn = <Quest>[
    Quest(QuestKind.correct, [5, 8, 12][rng.nextInt(3)], 200, 120),
    Quest(QuestKind.streak, [3, 4, 5][rng.nextInt(3)], 220, 120),
    Quest(QuestKind.exam, [4, 6][rng.nextInt(2)], 200, 110, param: rng.nextBool() ? 'AP1' : 'AP2'),
    if (topics.isNotEmpty)
      Quest(QuestKind.topic, 3, 250, 140, param: topics[rng.nextInt(topics.length)]),
  ]..shuffle(rng);
  final run = <Quest>[
    Quest(QuestKind.coins, [100, 200, 300][rng.nextInt(3)], 150, 80),
    Quest(QuestKind.distance, [1000, 1500, 2500][rng.nextInt(3)], 180, 90),
    Quest(QuestKind.rollUnder, [5, 8][rng.nextInt(2)], 160, 80),
    Quest(QuestKind.jumpOver, [5, 8][rng.nextInt(2)], 160, 80),
    Quest(QuestKind.powerUps, [2, 4][rng.nextInt(2)], 170, 90),
  ]..shuffle(rng);
  return [learn[0], learn[1], run[0]];
}
