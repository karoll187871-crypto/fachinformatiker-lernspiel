import 'dart:math';

/// Aussehen der Spielfigur. Farben als ARGB-Ints, damit die Spiellogik
/// ohne Flutter auskommt.
enum Accessory { none, cap, headphones, beanie, crown }

enum Pattern { plain, stripes, camo, binary }

class PlayerLook {
  const PlayerLook({
    required this.hoodie,
    required this.pants,
    this.shoes = 0xFFFAFAFA,
    this.skin = 0xFFE0A872,
    this.hair = 0xFF2B1D14,
    this.pack = 0xFFFF8F00,
    this.accessory = Accessory.none,
    this.accessoryColor = 0xFF263238,
    this.pattern = Pattern.plain,
    this.patternColor = 0xFF000000,
  });

  final int hoodie, pants, shoes, skin, hair, pack;
  final Accessory accessory;
  final int accessoryColor;
  final Pattern pattern;
  final int patternColor;
}

class Skin {
  const Skin(this.id, this.name, this.price, this.look,
      {this.minLevel = 1, this.boxOnly = false, this.description = ''});
  final String id;
  final String name;
  final int price;
  final int minLevel;
  final bool boxOnly; // nur aus der Wissens-Kiste
  final String description;
  final PlayerLook look;
}

const List<Skin> kSkins = [
  Skin('azubi', 'Azubi', 0,
      PlayerLook(hoodie: 0xFF1E88E5, pants: 0xFF263238),
      description: 'Erster Tag im Betrieb.'),
  Skin('admin', 'Sysadmin', 600,
      PlayerLook(
          hoodie: 0xFF212121,
          pants: 0xFF37474F,
          pack: 0xFF00C853,
          accessory: Accessory.headphones,
          accessoryColor: 0xFF00E676,
          pattern: Pattern.binary,
          patternColor: 0xFF00E676),
      description: 'Hört nur Lüfterrauschen.'),
  Skin('camo_wald', 'Tarnung Wald', 750,
      PlayerLook(
          hoodie: 0xFF556B2F,
          pants: 0xFF3E4A2A,
          pack: 0xFF6B4F2A,
          accessory: Accessory.beanie,
          accessoryColor: 0xFF3E4A2A,
          pattern: Pattern.camo,
          patternColor: 0xFF2F3B1C),
      description: 'Unsichtbar im Serverraum.'),
  Skin('camo_wueste', 'Tarnung Wüste', 750,
      PlayerLook(
          hoodie: 0xFFC2A66B,
          pants: 0xFF8D7448,
          pack: 0xFF7A5C2E,
          accessory: Accessory.cap,
          accessoryColor: 0xFF8D7448,
          pattern: Pattern.camo,
          patternColor: 0xFF8D6E3F)),
  Skin('camo_urban', 'Tarnung Urban', 750,
      PlayerLook(
          hoodie: 0xFF78909C,
          pants: 0xFF37474F,
          pack: 0xFF263238,
          pattern: Pattern.camo,
          patternColor: 0xFF455A64)),
  Skin('scrum', 'Scrum-Master', 800,
      PlayerLook(
          hoodie: 0xFFFF7043,
          pants: 0xFF3E2723,
          pack: 0xFF5D4037,
          accessory: Accessory.beanie,
          accessoryColor: 0xFFFFCA28),
      description: 'Daily um 9:15, pünktlich.'),
  Skin('hacker', 'White-Hat', 900,
      PlayerLook(
          hoodie: 0xFF424242,
          pants: 0xFF212121,
          hair: 0xFFECEFF1,
          pack: 0xFFECEFF1,
          accessory: Accessory.cap,
          accessoryColor: 0xFFFAFAFA),
      description: 'Pentests nur mit Auftrag.'),
  Skin('cloud', 'Cloud-Architekt', 1000,
      PlayerLook(
          hoodie: 0xFF4FC3F7,
          pants: 0xFF0D47A1,
          pack: 0xFFFFFFFF,
          accessory: Accessory.cap,
          accessoryColor: 0xFF0D47A1,
          pattern: Pattern.stripes,
          patternColor: 0xFFFFFFFF)),
  Skin('neon', 'Neon-Runner', 1100,
      PlayerLook(
          hoodie: 0xFFD500F9,
          pants: 0xFF1A0033,
          shoes: 0xFF00E5FF,
          pack: 0xFF00E5FF,
          pattern: Pattern.stripes,
          patternColor: 0xFF00E5FF),
      minLevel: 3),
  Skin('ninja', 'Firewall-Ninja', 1300,
      PlayerLook(
          hoodie: 0xFF1B1B1B,
          pants: 0xFF1B1B1B,
          shoes: 0xFFD32F2F,
          hair: 0xFF1B1B1B,
          pack: 0xFFD32F2F,
          accessory: Accessory.headphones,
          accessoryColor: 0xFFD32F2F,
          pattern: Pattern.stripes,
          patternColor: 0xFFD32F2F),
      minLevel: 5),
  Skin('pruefer', 'IHK-Prüfer', 1500,
      PlayerLook(
          hoodie: 0xFF283593,
          pants: 0xFF1A237E,
          shoes: 0xFF3E2723,
          hair: 0xFF9E9E9E,
          pack: 0xFF6D4C41,
          pattern: Pattern.stripes,
          patternColor: 0xFFE8EAF6),
      minLevel: 10,
      description: 'Ab Level 10.'),
  Skin('gold', 'Goldene Ausbildung', 0,
      PlayerLook(
          hoodie: 0xFFFFC107,
          pants: 0xFF6D4C00,
          shoes: 0xFFFFF59D,
          pack: 0xFFFFE082,
          accessory: Accessory.crown,
          accessoryColor: 0xFFFFD54F,
          pattern: Pattern.stripes,
          patternColor: 0xFFFFF8E1),
      boxOnly: true,
      description: 'Nur aus der Wissens-Kiste.'),
  Skin('matrix', 'Matrix', 0,
      PlayerLook(
          hoodie: 0xFF0B1F0B,
          pants: 0xFF0B1F0B,
          shoes: 0xFF00E676,
          hair: 0xFF000000,
          pack: 0xFF00C853,
          accessory: Accessory.headphones,
          accessoryColor: 0xFF00E676,
          pattern: Pattern.binary,
          patternColor: 0xFF69F0AE),
      boxOnly: true,
      description: 'Nur aus der Wissens-Kiste.'),
];

Skin skinById(String id) =>
    kSkins.firstWhere((s) => s.id == id, orElse: () => kSkins.first);

/// Lauf-Effekt (Partikelspur hinter der Figur).
class Trail {
  const Trail(this.id, this.name, this.price, this.colors,
      {this.boxOnly = false});
  final String id;
  final String name;
  final int price;
  final List<int> colors;
  final bool boxOnly;
}

const List<Trail> kTrails = [
  Trail('none', 'Keine Spur', 0, []),
  Trail('funken', 'Funken', 400, [0xFFFFD54F, 0xFFFFA000]),
  Trail('binaer', 'Binärcode', 600, [0xFF00E676, 0xFF69F0AE]),
  Trail('herzen', 'Herzen', 600, [0xFFFF4081, 0xFFFF80AB]),
  Trail('plasma', 'Plasma', 900, [0xFF00E5FF, 0xFFD500F9]),
  Trail('feuer', 'Feuer', 1000, [0xFFFF3D00, 0xFFFF9100, 0xFFFFEA00]),
  Trail('regenbogen', 'Regenbogen', 0,
      [0xFFFF1744, 0xFFFF9100, 0xFFFFEA00, 0xFF00E676, 0xFF2979FF, 0xFFD500F9],
      boxOnly: true),
];

Trail trailById(String id) =>
    kTrails.firstWhere((t) => t.id == id, orElse: () => kTrails.first);

const int kBoxPrice = 350;

/// Ergebnis einer geöffneten Wissens-Kiste.
class BoxReward {
  BoxReward({this.coins = 0, this.xp = 0, this.skin, this.trail});
  final int coins;
  final int xp;
  final Skin? skin;
  final Trail? trail;

  String get title {
    if (skin != null) return 'Neuer Skin: ${skin!.name}!';
    if (trail != null) return 'Neue Spur: ${trail!.name}!';
    if (xp > 0) return '+$xp XP';
    return '+$coins Münzen';
  }
}

BoxReward rollBox(Random rng, Set<String> ownedSkins, Set<String> ownedTrails) {
  final r = rng.nextDouble();
  final freeSkins = kSkins.where((s) => !ownedSkins.contains(s.id) && s.id != 'azubi').toList();
  final freeTrails = kTrails.where((t) => !ownedTrails.contains(t.id) && t.id != 'none').toList();
  if (r < 0.22 && freeSkins.isNotEmpty) {
    // Box-exklusive Skins sind seltener
    freeSkins.sort((a, b) => (a.boxOnly ? 1 : 0).compareTo(b.boxOnly ? 1 : 0));
    final pick = rng.nextDouble() < 0.3 && freeSkins.any((s) => s.boxOnly)
        ? freeSkins.where((s) => s.boxOnly).toList()[rng.nextInt(freeSkins.where((s) => s.boxOnly).length)]
        : freeSkins[rng.nextInt(freeSkins.length)];
    return BoxReward(skin: pick);
  }
  if (r < 0.40 && freeTrails.isNotEmpty) {
    return BoxReward(trail: freeTrails[rng.nextInt(freeTrails.length)]);
  }
  if (r < 0.62) return BoxReward(xp: 100 + rng.nextInt(5) * 50);
  if (r < 0.70) return BoxReward(coins: 1000);
  return BoxReward(coins: 120 + rng.nextInt(9) * 40);
}

// ------------------------------------------------------------ Level & Story

int xpForLevel(int level) => 50 * level * (level - 1);

int levelForXp(int xp) {
  var l = 1;
  while (xpForLevel(l + 1) <= xp) {
    l++;
  }
  return l;
}

class Chapter {
  const Chapter(this.level, this.title, this.story);
  final int level;
  final String title;
  final String story;
}

const List<Chapter> kChapters = [
  Chapter(1, 'Erster Tag',
      'Du startest deine Ausbildung bei der NordByte GmbH. Dein Ausbilder grinst: „Lauf dich warm – die Prüfung wartet nicht.“'),
  Chapter(3, 'Netzwerk-Chaos',
      'Das Firmennetz ist ausgefallen. Nur wer IP-Adressen, Subnetze und das OSI-Modell kennt, findet den Weg zum Switch.'),
  Chapter(5, 'Die Phishing-Welle',
      'Verdächtige Mails überall. Zeig, dass du Schutzziele, Verschlüsselung und Social Engineering durchschaust.'),
  Chapter(8, 'Countdown AP1',
      'Die Zwischenprüfung steht vor der Tür. Arbeitsplatz einrichten, Angebote vergleichen, Kunden beraten – alles muss sitzen.'),
  Chapter(12, 'Das Abschlussprojekt',
      'Dein Projekt: planen, umsetzen, dokumentieren. Scrum, Gantt und Kosten – du hast die Zügel in der Hand.'),
  Chapter(16, 'Datenbank-Dschungel',
      'Die Kundendaten liegen in zehn Excel-Listen. Normalisieren, SQL schreiben, Ordnung schaffen.'),
  Chapter(20, 'AP2 – Der Endgegner',
      'Die Abschlussprüfung. Entwurfsmuster, Algorithmen, WiSo. Jetzt zählt jede Antwort.'),
  Chapter(25, 'Ausgelernt!',
      'Du hast es geschafft: Fachinformatiker:in. Aber Lernen hört nie auf – lauf weiter und bleib fit.'),
];

Chapter chapterForLevel(int level) =>
    kChapters.lastWhere((c) => c.level <= level, orElse: () => kChapters.first);

Chapter? nextChapter(int level) {
  for (final c in kChapters) {
    if (c.level > level) return c;
  }
  return null;
}

// ------------------------------------------------------------------ Himmel

/// Himmel im Spiel. Farben von oben nach unten bis zum Horizont.
class SkyTheme {
  const SkyTheme(this.id, this.name, this.price, this.colors, this.fog,
      {this.sunTop = 0xFFFFE08A,
      this.sunBottom = 0xFFFF7A59,
      this.sunGlow = 0x66FFB36B,
      this.stars = true,
      this.skyline = 0xFF3B2150,
      this.custom = false});
  final String id;
  final String name;
  final int price;
  final List<int> colors; // 4 Farbstufen
  final int fog; // Nebel-/Horizontfarbe
  final int sunTop, sunBottom, sunGlow;
  final bool stars;
  final int skyline;
  final bool custom; // eigenes Bild
}

const int kCustomSkyPrice = 5000;

const List<SkyTheme> kSkies = [
  SkyTheme('sunset', 'Abendrot', 0, [0xFF0A0E24, 0xFF2A1A4A, 0xFF8A3A68, 0xFFF2894E], 0xFF6B3A6E),
  SkyTheme('night', 'Mitternacht', 500, [0xFF02040F, 0xFF0B1033, 0xFF1A2050, 0xFF2B3470], 0xFF262B52,
      sunTop: 0xFFF5F3E6, sunBottom: 0xFFC9CCE0, sunGlow: 0x40D0D8FF, skyline: 0xFF141833),
  SkyTheme('day', 'Sommertag', 600, [0xFF1E6FD9, 0xFF4FA3F0, 0xFF9FD3FA, 0xFFDDF1FF], 0xFF8FA9C4,
      sunTop: 0xFFFFFDE7, sunBottom: 0xFFFFF176, sunGlow: 0x80FFFFFF, stars: false, skyline: 0xFF7088A6),
  SkyTheme('synth', 'Synthwave', 800, [0xFF12002B, 0xFF4A0A6B, 0xFFB0137A, 0xFFFF6A3D], 0xFF5E1B5E,
      sunTop: 0xFFFFF176, sunBottom: 0xFFFF2D95, sunGlow: 0x80FF2D95, skyline: 0xFF2A0840),
  SkyTheme('mars', 'Mars', 900, [0xFF2B0A05, 0xFF6B1E0E, 0xFFB5481F, 0xFFE89A5B], 0xFF7A3A22,
      sunTop: 0xFFE3F2FD, sunBottom: 0xFF90CAF9, sunGlow: 0x5090CAF9, stars: false, skyline: 0xFF3E120A),
  SkyTheme('aurora', 'Polarlicht', 1000, [0xFF020B12, 0xFF07303A, 0xFF0E6B5C, 0xFF5FE3A1], 0xFF17434A,
      sunTop: 0xFFE0F7FA, sunBottom: 0xFF80DEEA, sunGlow: 0x4080DEEA, skyline: 0xFF06222A),
  SkyTheme('custom', 'Eigenes Bild', kCustomSkyPrice, [0xFF000000, 0xFF000000, 0xFF000000, 0xFF000000],
      0xFF6B3A6E, custom: true, stars: false),
];

SkyTheme skyById(String id) =>
    kSkies.firstWhere((s) => s.id == id, orElse: () => kSkies.first);
