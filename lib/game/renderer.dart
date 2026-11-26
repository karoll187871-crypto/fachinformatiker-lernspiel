import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../data/cosmetics.dart';
import 'engine.dart';
import 'sky.dart';

/// Grafikqualität: 2 = hoch, 1 = mittel, 0 = niedrig.
/// Wird von [QualityGovernor] automatisch angepasst.
class RenderSettings {
  static int level = 2;
}

/// Sammelt alle Dreiecke eines Frames und zeichnet sie mit EINEM
/// drawVertices-Aufruf. Das ist um ein Vielfaches schneller als tausende
/// einzelne drawPath-Aufrufe.
class _Batch {
  Float32List _pos = Float32List(24000 * 2);
  Int32List _col = Int32List(24000);
  int _n = 0;
  final Paint _paint = Paint();

  void _grow(int add) {
    if (_n + add <= _col.length) return;
    var cap = _col.length * 2;
    while (cap < _n + add) {
      cap *= 2;
    }
    final p = Float32List(cap * 2)..setRange(0, _n * 2, _pos);
    final c = Int32List(cap)..setRange(0, _n, _col);
    _pos = p;
    _col = c;
  }

  @pragma('vm:prefer-inline')
  void _v(double x, double y, int c) {
    final i = _n * 2;
    _pos[i] = x;
    _pos[i + 1] = y;
    _col[_n] = c;
    _n++;
  }

  void tri(Offset a, Offset b, Offset c, int ca, int cb, int cc) {
    _grow(3);
    _v(a.dx, a.dy, ca);
    _v(b.dx, b.dy, cb);
    _v(c.dx, c.dy, cc);
  }

  void quad(Offset a, Offset b, Offset c, Offset d, int ca, int cb, int cc, int cd) {
    _grow(6);
    _v(a.dx, a.dy, ca);
    _v(b.dx, b.dy, cb);
    _v(c.dx, c.dy, cc);
    _v(a.dx, a.dy, ca);
    _v(c.dx, c.dy, cc);
    _v(d.dx, d.dy, cd);
  }

  void flush(Canvas canvas) {
    if (_n == 0) return;
    final v = ui.Vertices.raw(
      ui.VertexMode.triangles,
      Float32List.sublistView(_pos, 0, _n * 2),
      colors: Int32List.sublistView(_col, 0, _n),
    );
    canvas.drawVertices(v, BlendMode.dst, _paint);
    v.dispose();
    _n = 0;
  }
}

// Vorberechnete Kreis-Tabellen für Fächer (Kreise, Glühen, Münzen).
final Map<int, (Float64List, Float64List)> _circleTables = {};
(Float64List, Float64List) _circle(int segs) => _circleTables.putIfAbsent(segs, () {
      final c = Float64List(segs + 1), s = Float64List(segs + 1);
      for (var i = 0; i <= segs; i++) {
        c[i] = cos(i / segs * pi * 2);
        s[i] = sin(i / segs * pi * 2);
      }
      return (c, s);
    });

/// Zeichnet die Spielwelt mit echter Perspektivprojektion (3D)
/// auf ein Canvas. Skaliert automatisch auf jede Fenstergröße.
class RunnerPainter extends CustomPainter {
  RunnerPainter(this.game, Listenable repaint) : super(repaint: repaint);

  final RunnerGame game;
  static final _Batch _b = _Batch();

  // Kamera
  late double _w, _h, _cx, _horizon, _f, _camX, _camY, _fogFar;
  static const double _camZ = -7.4;
  static const double _fogNear = 30;

  static int get _fogColor => SkyStore.fog;

  late int _q; // Qualitätsstufe dieses Frames

  // Wird während paint gesetzt, damit die Closures Zugriff haben.
  Canvas? canvas;

  @override
  void paint(Canvas canvas, Size size) {
    this.canvas = canvas;
    _q = RenderSettings.level;
    _fogFar = const [105.0, 135.0, 165.0][_q];
    _w = size.width;
    _h = size.height;
    _cx = _w / 2;
    final portrait = _h > _w * 1.1;
    // Hochkant: Gleise füllen die Breite, Horizont etwas tiefer
    _f = portrait ? _w * 1.02 : min(_h * 1.0, _w * 0.62) * 0.92;
    final sh = game.shake;
    final shakeX = sh > 0 ? sin(game.time * 90) * sh * 0.25 : 0.0;
    final shakeY = sh > 0 ? cos(game.time * 77) * sh * 0.12 : 0.0;
    _horizon = _h * (portrait ? 0.40 : 0.36) + shakeY * _h * 0.05;
    _camX = game.px * 0.55 + shakeX;
    _camY = 3.5 + game.py * 0.28;

    _drawSky();
    _drawGround();
    _drawTrack();

    final items = <_Item>[];
    _collectScenery(items);
    for (final o in game.obstacles) {
      final z = o.wz - game.distance;
      if (z > _fogFar || z + o.length < _camZ + 0.5) continue;
      final depth = o.kind == ObstacleKind.train ? z + o.length * 0.5 : z;
      items.add(_Item(depth, () => _drawObstacle(o, z)));
    }
    final coinFar = min(120.0, _fogFar);
    for (final c in game.coinItems) {
      if (c.taken) continue;
      final z = c.wz - game.distance;
      if (z > coinFar || z < _camZ + 1) continue;
      items.add(_Item(z, () => _drawCoin(c, z)));
    }
    for (final p in game.powerItems) {
      if (p.taken) continue;
      final z = p.wz - game.distance;
      if (z > coinFar || z < _camZ + 1) continue;
      items.add(_Item(z, () => _drawPower(p, z)));
    }
    for (final g in game.gates) {
      final z = g.wz - game.distance;
      if (z > _fogFar || z < _camZ + 1) continue;
      items.add(_Item(z + 0.1, () => _drawGate(g, z)));
    }
    items.add(_Item(0.0, _drawPlayer));
    for (final p in game.particles) {
      final z = p.wz - game.distance;
      if (z < _camZ + 0.8) continue;
      items.add(_Item(z - 0.2, () => _drawParticle(p, z)));
    }
    items.sort((a, b) => b.depth.compareTo(a.depth));
    for (final it in items) {
      it.draw();
    }
    if (_q > 0) _drawVignette();
    _b.flush(canvas);
  }

  // ------------------------------------------------------------ Projektion

  Offset _p(double x, double y, double z) {
    final dz = max(z - _camZ, 0.3);
    final k = _f / dz;
    return Offset(_cx + (x - _camX) * k, _horizon - (y - _camY) * k);
  }

  double _scale(double z) => _f / max(z - _camZ, 0.3);

  double _fogT(double z) {
    final t = ((z - _camZ - _fogNear) / (_fogFar - _fogNear)).clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  /// Lineare Farbmischung direkt auf ARGB-Ints (schnell, keine Objekte).
  static int _mix(int a, int b, double t) {
    if (t <= 0) return a;
    if (t >= 1) return b;
    final aa = (a >> 24) & 0xFF, ar = (a >> 16) & 0xFF, ag = (a >> 8) & 0xFF, ab = a & 0xFF;
    final ba = (b >> 24) & 0xFF, br = (b >> 16) & 0xFF, bg = (b >> 8) & 0xFF, bb = b & 0xFF;
    return ((aa + (ba - aa) * t).round() << 24) |
        ((ar + (br - ar) * t).round() << 16) |
        ((ag + (bg - ag) * t).round() << 8) |
        (ab + (bb - ab) * t).round();
  }

  static int _alpha(int c, double a) =>
      (((c >> 24) & 0xFF) * a.clamp(0.0, 1.0)).round() << 24 | (c & 0xFFFFFF);

  int _fog(int c, double z) {
    final t = _fogT(z);
    if (t <= 0) return c;
    final a = c & 0xFF000000;
    return a | (_mix(c, _fogColor, t) & 0xFFFFFF);
  }

  static int _shade(int c, double f) {
    if (f >= 1) return _mix(c, 0xFFFFFFFF | (c & 0xFF000000), (f - 1).clamp(0.0, 1.0));
    final a = c & 0xFF000000;
    return a | (_mix(0xFF000000, c, f.clamp(0.0, 1.0)) & 0xFFFFFF);
  }

  void _quad(Offset a, Offset b, Offset c, Offset d, int col) =>
      _b.quad(a, b, c, d, col, col, col, col);

  /// Gefüllte Ellipse / Kreis als Dreiecksfächer.
  void _fan(Offset c, double rx, double ry, int center, int rim, {int segs = 12}) {
    final (co, si) = _circle(segs);
    for (var i = 0; i < segs; i++) {
      _b.tri(c, Offset(c.dx + co[i] * rx, c.dy + si[i] * ry),
          Offset(c.dx + co[i + 1] * rx, c.dy + si[i + 1] * ry), center, rim, rim);
    }
  }

  void _disc(Offset c, double r, int col, {int segs = 12}) =>
      _fan(c, r, r, col, col, segs: segs);

  void _glow(Offset c, double r, int col, {int segs = 12}) =>
      _fan(c, r, r, col, col & 0x00FFFFFF, segs: segs);

  /// Dicke Linie zwischen zwei Bildschirmpunkten.
  void _line(Offset a, Offset b, double w, int col) {
    final d = b - a;
    final len = d.distance;
    if (len < 0.01) return;
    final n = Offset(-d.dy / len * w / 2, d.dx / len * w / 2);
    _quad(a + n, b + n, b - n, a - n, col);
  }

  /// Quader mit sichtbaren Flächen (Seiten, Deckel, Front).
  void _box(double x0, double x1, double y0, double y1, double z0, double z1, int col,
      {int? top, int? side, double? fogZ}) {
    if (z1 - _camZ < 0.35) return;
    final zf = max(z0, _camZ + 0.35);
    final fz = fogZ ?? zf;
    final sideCol = _fog(side ?? _shade(col, 0.62), fz);
    if (_camX < x0) {
      _quad(_p(x0, y0, zf), _p(x0, y1, zf), _p(x0, y1, z1), _p(x0, y0, z1), sideCol);
    }
    if (_camX > x1) {
      _quad(_p(x1, y0, zf), _p(x1, y1, zf), _p(x1, y1, z1), _p(x1, y0, z1), sideCol);
    }
    if (_camY > y1) {
      _quad(_p(x0, y1, zf), _p(x1, y1, zf), _p(x1, y1, z1), _p(x0, y1, z1),
          _fog(top ?? _shade(col, 1.18), fz));
    }
    _quad(_p(x0, y0, zf), _p(x1, y0, zf), _p(x1, y1, zf), _p(x0, y1, zf), _fog(col, fz));
  }

  /// Flacher Streifen am Boden in Laufrichtung, Farbe verblasst mit Nebel.
  static const List<double> _stripZ = [-7.0, 0, 10, 25, 45, 70, 100, 135, 165];
  void _strip(double x0, double x1, double y, int col) {
    for (var i = 0; i < _stripZ.length - 1; i++) {
      final za = max(_stripZ[i], _camZ + 0.4);
      final zb = min(_stripZ[i + 1], _fogFar);
      if (zb <= za) break;
      final ca = _fog(col, za), cb = _fog(col, zb);
      _b.quad(_p(x0, y, za), _p(x1, y, za), _p(x1, y, zb), _p(x0, y, zb), ca, ca, cb, cb);
    }
  }

  /// Senkrechter Streifen (z. B. Bahnsteigkante) in Laufrichtung.
  void _wall(double x, double y0, double y1, int col) {
    for (var i = 0; i < _stripZ.length - 1; i++) {
      final za = max(_stripZ[i], _camZ + 0.4);
      final zb = min(_stripZ[i + 1], _fogFar);
      if (zb <= za) break;
      final ca = _fog(col, za), cb = _fog(col, zb);
      _b.quad(_p(x, y0, za), _p(x, y1, za), _p(x, y1, zb), _p(x, y0, zb), ca, ca, cb, cb);
    }
  }

  // ------------------------------------------------------------- Umgebung

  static final List<(double, double, double, double)> _stars = () {
    final rnd = Random(7);
    return List.generate(
        70, (_) => (rnd.nextDouble(), rnd.nextDouble(), 0.6 + rnd.nextDouble() * 1.1, rnd.nextDouble() * 6));
  }();

  void _drawSky() {
    final hz = _horizon + 2;
    final sky = SkyStore.theme;
    final img = SkyStore.image;
    if (sky.custom && img != null) {
      _drawSkyImage(img, hz);
      return;
    }
    const stops = [0.0, 0.45, 0.82, 1.0];
    final cols = sky.colors;
    for (var i = 0; i < 3; i++) {
      final y0 = stops[i] * hz, y1 = stops[i + 1] * hz;
      _b.quad(Offset(0, y0), Offset(_w, y0), Offset(_w, y1), Offset(0, y1), cols[i], cols[i],
          cols[i + 1], cols[i + 1]);
    }

    // Sterne (funkeln)
    final count = sky.stars ? const [0, 35, 70][_q] : 0;
    for (var i = 0; i < count; i++) {
      final (sx, sy, r, ph) = _stars[i];
      final tw = 0.5 + 0.5 * sin(game.time * 2 + ph);
      final c = Offset(sx * _w, sy * _horizon * 0.55);
      final col = _alpha(0xFFFFFFFF, 0.25 + 0.5 * tw);
      _b.quad(c.translate(0, -r), c.translate(r, 0), c.translate(0, r), c.translate(-r, 0), col,
          col, col, col);
    }

    // Sonne mit Glühen
    final sun = Offset(_cx - _camX * 6, _horizon - _h * 0.07);
    final r = _h * 0.12;
    _glow(sun, r * 2.4, sky.sunGlow, segs: 24);
    final (co, si) = _circle(28);
    for (var i = 0; i < 28; i++) {
      final a = Offset(sun.dx + co[i] * r, sun.dy + si[i] * r);
      final b = Offset(sun.dx + co[i + 1] * r, sun.dy + si[i + 1] * r);
      _b.tri(sun, a, b, _mix(sky.sunTop, sky.sunBottom, 0.5), _mix(sky.sunTop, sky.sunBottom, (si[i] + 1) / 2),
          _mix(sky.sunTop, sky.sunBottom, (si[i + 1] + 1) / 2));
    }

    // Ferne Skyline (Parallaxe)
    final rs = Random(42);
    final par = _camX * 3;
    var x = -60.0 - par;
    while (x < _w + 60) {
      final bw = _w * (0.025 + rs.nextDouble() * 0.05);
      final bh = _h * (0.03 + rs.nextDouble() * 0.12);
      _quad(Offset(x, _horizon - bh), Offset(x + bw + 1, _horizon - bh),
          Offset(x + bw + 1, _horizon + 1), Offset(x, _horizon + 1), sky.skyline);
      x += bw;
    }
  }

  /// Eigenes Bild als Himmel: füllt den Bereich über dem Horizont
  /// (wie „cover“), bewegt sich leicht mit der Kamera (Parallaxe).
  final Paint _imgPaint = Paint()..filterQuality = FilterQuality.medium;

  void _drawSkyImage(ui.Image img, double hz) {
    final c = canvas!;
    final iw = img.width.toDouble(), ih = img.height.toDouble();
    final extra = _w * 0.06; // Rand für Parallaxe
    final scale = max((_w + extra * 2) / iw, hz / ih);
    final dw = iw * scale, dh = ih * scale;
    final dx = (_w - dw) / 2 - _camX * extra * 0.12;
    final dy = hz - dh; // unten am Horizont ausrichten
    c.drawImageRect(img, Rect.fromLTWH(0, 0, iw, ih), Rect.fromLTWH(dx, dy, dw, dh), _imgPaint);
    // Weicher Übergang in den Horizont-Dunst
    final fogTop = hz - _h * 0.08;
    _b.quad(Offset(0, fogTop), Offset(_w, fogTop), Offset(_w, hz), Offset(0, hz),
        _fogColor & 0x00FFFFFF, _fogColor & 0x00FFFFFF, _fogColor, _fogColor);
  }

  void _drawGround() {
    final y1 = _horizon + (_h - _horizon) * 0.25;
    _b.quad(Offset(0, _horizon), Offset(_w, _horizon), Offset(_w, y1), Offset(0, y1), _fogColor,
        _fogColor, 0xFF2A2140, 0xFF2A2140);
    _b.quad(Offset(0, y1), Offset(_w, y1), Offset(_w, _h), Offset(0, _h), 0xFF2A2140, 0xFF2A2140,
        0xFF15111F, 0xFF15111F);
  }

  void _drawTrack() {
    // Gleisbett
    _strip(-3.6, 3.6, 0, 0xFF332B3A);

    // Schwellen
    final spacing = _q == 0 ? 2.2 : 1.5;
    final offset = game.distance % spacing;
    final far = min(110.0, _fogFar);
    for (var z = far - offset; z > _camZ + 0.5; z -= spacing) {
      final col = _fog(0xFF5A4636, z);
      for (final lane in const [-1, 0, 1]) {
        final lx = lane * kLaneWidth;
        _quad(_p(lx - 1.0, 0.02, z), _p(lx + 1.0, 0.02, z), _p(lx + 1.0, 0.02, z + 0.4),
            _p(lx - 1.0, 0.02, z + 0.4), col);
      }
    }

    // Schienen
    for (final lane in const [-1, 0, 1]) {
      for (final s in const [-0.72, 0.72]) {
        final x = lane * kLaneWidth + s;
        _strip(x - 0.07, x + 0.07, 0.14, 0xFFB8C2D6);
      }
    }

    // Bahnsteigkanten mit gelber Sicherheitslinie
    for (final side in const [-1.0, 1.0]) {
      final xi = side * 3.7, xo = side * 5.2;
      const top = 0.45;
      _wall(xi, 0, top, 0xFF3E3850);
      _strip(min(xi, xo), max(xi, xo), top, 0xFF5B5470);
      final ya = xi + side * 0.15, yb = xi + side * 0.35;
      _strip(min(ya, yb), max(ya, yb), top + 0.01, 0xFFFFC94A);
    }
  }

  static double _hash(int n) {
    var x = (n * 374761393 + 668265263) & 0x7fffffff;
    x = ((x ^ (x >> 13)) * 1274126177) & 0x7fffffff;
    return (x & 0xffff) / 0xffff;
  }

  static const List<int> _buildingColors = [
    0xFF3B3F6B,
    0xFF4A3560,
    0xFF2E4A62,
    0xFF5A3D52,
    0xFF34405A,
  ];

  void _collectScenery(List<_Item> items) {
    final dist = game.distance;
    // Gebäude
    const slot = 11.0;
    final first = ((dist + _camZ) / slot).floor();
    for (var k = 0; k < 17; k++) {
      final idx = first + k;
      final z0 = idx * slot - dist;
      if (z0 > _fogFar || z0 + 9 < _camZ + 0.5) continue;
      for (final side in const [-1, 1]) {
        final seed = idx * 2 + (side > 0 ? 1 : 0);
        final inner = 6.6 + _hash(seed) * 2.0;
        final width = 5 + _hash(seed + 11) * 6;
        final height = 7 + _hash(seed + 23) * 22;
        final depth = 8.0 + _hash(seed + 5) * 1.5;
        final col = _buildingColors[(_hash(seed + 3) * 5).floor() % 5];
        items.add(_Item(z0 + depth * 0.5 + 0.5, () {
          _drawBuilding(side, inner, width, height, z0, depth, col, seed);
        }));
      }
    }
    // Laternen
    const lampSlot = 17.0;
    final lf = ((dist + _camZ) / lampSlot).floor();
    for (var k = 0; k < 11; k++) {
      final z = (lf + k) * lampSlot - dist;
      if (z > _fogFar || z < _camZ + 0.8) continue;
      for (final side in const [-1.0, 1.0]) {
        items.add(_Item(z, () => _drawLamp(side, z)));
      }
    }
    // Portale über den Gleisen
    const gSlot = 51.0;
    final gf = ((dist + _camZ) / gSlot).floor();
    for (var k = 0; k < 5; k++) {
      final z = (gf + k) * gSlot + 8 - dist;
      if (z > _fogFar || z < _camZ + 0.8) continue;
      items.add(_Item(z, () => _drawGantry(z)));
    }
  }

  void _drawBuilding(int side, double inner, double width, double height, double z0,
      double depth, int col, int seed) {
    final x0 = side < 0 ? -inner - width : inner;
    final x1 = side < 0 ? -inner : inner + width;
    final z1 = z0 + depth;
    _box(x0, x1, 0, height, z0, z1, col, fogZ: z0 + depth * 0.3);
    if (_q == 0 || z0 > 125) return;
    // Fenster an der Front und an der Gleisseite
    final rows = (height / 2.3).floor();
    const lit = 0xFFFFD27A;
    final dark = _shade(col, 0.55);
    final zf = max(z0, _camZ + 0.4);
    final litF = _fog(lit, zf), darkF = _fog(dark, zf);
    // Front
    final cols = (width / 1.8).floor();
    for (var r = 0; r < rows; r++) {
      for (var k = 0; k < cols; k++) {
        final on = _hash(seed * 131 + r * 17 + k) > 0.45;
        final wx0 = x0 + 0.6 + k * 1.8, wy0 = 1.2 + r * 2.3;
        if (wx0 + 0.9 > x1 - 0.3 || wy0 + 1.1 > height - 0.4) continue;
        _quad(_p(wx0, wy0, zf), _p(wx0 + 0.9, wy0, zf), _p(wx0 + 0.9, wy0 + 1.1, zf),
            _p(wx0, wy0 + 1.1, zf), on ? litF : darkF);
      }
    }
    if (_q < 2) return;
    // Gleisseite (nur sichtbar, wenn Kamera innen)
    final xs = side < 0 ? x1 : x0;
    if ((side < 0 && _camX > xs) || (side > 0 && _camX < xs)) {
      final cs = (depth / 2.0).floor();
      for (var r = 0; r < rows; r++) {
        for (var k = 0; k < cs; k++) {
          final on = _hash(seed * 977 + r * 31 + k) > 0.5;
          final wz0 = z0 + 0.6 + k * 2.0, wy0 = 1.2 + r * 2.3;
          if (wz0 + 1.0 > z1 - 0.3 || wy0 + 1.1 > height - 0.4) continue;
          if (wz0 < _camZ + 0.5) continue;
          _quad(_p(xs, wy0, wz0), _p(xs, wy0, wz0 + 1.0), _p(xs, wy0 + 1.1, wz0 + 1.0),
              _p(xs, wy0 + 1.1, wz0), _fog(on ? lit : dark, wz0));
        }
      }
    }
  }

  void _drawLamp(double side, double z) {
    final x = side * 4.6;
    _box(x - 0.08, x + 0.08, 0.45, 5.6, z, z + 0.16, 0xFF4A4A5A);
    final armEnd = side * 3.9;
    _box(min(x, armEnd), max(x, armEnd), 5.5, 5.62, z, z + 0.14, 0xFF4A4A5A);
    final light = _p(armEnd, 5.45, z + 0.07);
    final t = 1 - _fogT(z);
    if (_q > 0) _glow(light, _scale(z) * 0.9, _alpha(0xFFFFDC8C, 0.6 * t), segs: 10);
    _disc(light, max(1.0, _scale(z) * 0.12), _mix(0xFFFFF3C4, _fogColor, _fogT(z)), segs: 8);
  }

  void _drawGantry(double z) {
    const col = 0xFF54506A;
    for (final x in const [-4.2, 4.2]) {
      _box(x - 0.18, x + 0.18, 0.45, 6.6, z, z + 0.36, col);
    }
    _box(-4.4, 4.4, 6.2, 6.7, z, z + 0.4, _shade(col, 1.1));
    // Signallichter
    for (final lane in const [-1, 0, 1]) {
      _disc(_p(lane * kLaneWidth, 5.95, z), max(1.5, _scale(z) * 0.13), _fog(0xFF7CFFB2, z),
          segs: 8);
    }
  }

  // ------------------------------------------------------------ Hindernisse

  static const List<int> _trainColors = [0xFF2F7FE0, 0xFFE0483C, 0xFF22A779, 0xFFE8A42A];

  void _drawObstacle(Obstacle o, double z) {
    final lx = o.lane * kLaneWidth;
    switch (o.kind) {
      case ObstacleKind.low:
        _drawLowBarrier(lx, z);
      case ObstacleKind.high:
        _drawHighBarrier(lx, z);
      case ObstacleKind.train:
        _drawTrain(lx, z, o.length, _trainColors[o.style % 4]);
    }
  }

  void _drawLowBarrier(double lx, double z) {
    const leg = 0xFF8A8FA3;
    for (final s in const [-0.8, 0.8]) {
      _box(lx + s - 0.07, lx + s + 0.07, 0, 0.55, z + 0.08, z + 0.24, leg);
    }
    _box(lx - 1.0, lx + 1.0, 0.45, 1.0, z, z + 0.25, 0xFFE53935);
    if (z - _camZ < 0.4) return;
    // Weiße Streifen auf der Front
    final white = _fog(0xFFFFFFFF, z);
    for (var i = 0; i < 5; i++) {
      final xa = lx - 1.0 + i * 0.42;
      _quad(_p(max(lx - 1.0, xa), 0.45, z), _p(min(lx + 1.0, xa + 0.2), 0.45, z),
          _p(min(lx + 1.0, xa + 0.45), 1.0, z), _p(min(lx + 1.0, xa + 0.25), 1.0, z), white);
    }
    // Blinklicht
    final on = (game.time * 3).floor().isEven;
    _disc(_p(lx, 1.12, z + 0.1), max(1.5, _scale(z) * 0.09),
        _fog(on ? 0xFFFFEB3B : 0xFF8D6E00, z), segs: 8);
  }

  void _drawHighBarrier(double lx, double z) {
    const post = 0xFF8A8FA3;
    for (final s in const [-0.95, 0.95]) {
      _box(lx + s - 0.09, lx + s + 0.09, 0, 2.5, z, z + 0.2, post);
    }
    _box(lx - 1.05, lx + 1.05, 1.35, 2.35, z, z + 0.22, 0xFFFFC107);
    if (z - _camZ < 0.4) return;
    final black = _fog(0xFF212121, z);
    // Pfeile nach unten (Rollen!)
    for (var i = 0; i < 3; i++) {
      final cxp = lx - 0.6 + i * 0.6;
      final a = _p(cxp - 0.2, 2.15, z), b = _p(cxp + 0.2, 2.15, z);
      final m = _p(cxp, 1.62, z);
      final a2 = _p(cxp - 0.2, 1.95, z), b2 = _p(cxp + 0.2, 1.95, z);
      final m2 = _p(cxp, 1.45, z);
      _quad(a, m, m2, a2, black);
      _quad(m, b, b2, m2, black);
    }
  }

  void _drawTrain(double lx, double z, double len, int col) {
    final x0 = lx - 1.0, x1 = lx + 1.0;
    final z1 = z + len;
    _box(x0 + 0.1, x1 - 0.1, 0, 0.35, z + 0.3, z1 - 0.3, 0xFF1E1E24);
    _box(x0, x1, 0.3, 3.3, z, z1, col, top: _shade(col, 0.85), side: _shade(col, 0.7));
    // Fensterband an der Seite
    final xs = _camX < x0 ? x0 : (_camX > x1 ? x1 : null);
    if (xs != null) {
      if (_q > 0) {
        for (var wz = z + 1.2; wz < z1 - 1.5; wz += 2.2) {
          if (wz < _camZ + 0.5) continue;
          _quad(_p(xs, 1.9, wz), _p(xs, 1.9, wz + 1.5), _p(xs, 2.8, wz + 1.5), _p(xs, 2.8, wz),
              _fog(0xFF1B2A44, wz));
        }
      }
      final zs = max(z, _camZ + 0.4);
      _quad(_p(xs, 1.1, zs), _p(xs, 1.1, z1), _p(xs, 1.3, z1), _p(xs, 1.3, zs),
          _fog(0xD9FFFFFF, zs));
    }
    if (z - _camZ < 0.4) return;
    // Front: Scheibe, Streifen, Scheinwerfer
    _quad(_p(x0 + 0.2, 1.9, z), _p(x1 - 0.2, 1.9, z), _p(x1 - 0.2, 3.0, z), _p(x0 + 0.2, 3.0, z),
        _fog(0xFF16243B, z));
    _quad(_p(x0 + 0.3, 2.75, z), _p(x0 + 0.8, 2.75, z), _p(x0 + 0.6, 2.95, z),
        _p(x0 + 0.3, 2.95, z), _fog(0x59FFFFFF, z));
    _quad(_p(x0, 1.1, z), _p(x1, 1.1, z), _p(x1, 1.3, z), _p(x0, 1.3, z), _fog(0xE6FFFFFF, z));
    final t = 1 - _fogT(z);
    for (final s in const [-0.6, 0.6]) {
      final lp = _p(lx + s, 0.75, z);
      final r = _scale(z) * 0.17;
      if (_q > 0) _glow(lp, r * 3.5, _alpha(0xFFFFF4C8, 0.67 * t), segs: 10);
      _disc(lp, r, _fog(0xFFFFF8E1, z), segs: 10);
    }
  }

  void _drawCoin(Coin coin, double z) {
    final center = _p(coin.lane * kLaneWidth, coin.y, z);
    final r = _scale(z) * 0.32;
    if (r < 0.8) return;
    final spin = cos(game.time * 5 + coin.wz * 0.7).abs();
    final rw = r * max(0.18, spin);
    final segs = r > 12 ? 14 : 8;
    _fan(center, rw * 1.08 + r * 0.04, r * 1.08, _fog(0xFFB8860B, z), _fog(0xFFB8860B, z),
        segs: segs);
    _fan(center, rw, r, _fog(0xFFFFE57F, z), _fog(0xFFFFC107, z), segs: segs);
    _fan(center - Offset(rw * 0.2, r * 0.2), rw * 0.35, r * 0.35, _fog(0xFFFFF9C4, z),
        _fog(0x00FFF9C4, z), segs: 8);
  }

  void _drawPower(PowerItem p, double z) {
    final bob = sin(game.time * 3 + p.wz) * 0.15;
    final y = 1.25 + bob;
    final c = _p(p.lane * kLaneWidth, y, z);
    final r = _scale(z) * 0.42;
    if (r < 1) return;
    final col = kPowerColors[p.kind]!;
    final fogT = _fogT(z);
    _glow(c, r * 2.2, _alpha(col, 0.55 * (1 - fogT)), segs: 14);
    _fan(c, r, r, _fog(_shade(col, 1.25), z), _fog(_shade(col, 0.75), z), segs: 16);
    final w = _fog(0xFFFFFFFF, z);
    final u = r * 0.45;
    switch (p.kind) {
      case PowerKind.magnet: // Hufeisen
        _quad(c + Offset(-u, -u), c + Offset(-u * 0.5, -u), c + Offset(-u * 0.5, u * 0.6),
            c + Offset(-u, u * 0.6), w);
        _quad(c + Offset(u * 0.5, -u), c + Offset(u, -u), c + Offset(u, u * 0.6),
            c + Offset(u * 0.5, u * 0.6), w);
        _quad(c + Offset(-u, u * 0.4), c + Offset(u, u * 0.4), c + Offset(u, u),
            c + Offset(-u, u), w);
      case PowerKind.shield:
        _fan(c, u, u * 1.15, w, w, segs: 12);
        _fan(c, u * 0.6, u * 0.7, _fog(col, z), _fog(col, z), segs: 12);
      case PowerKind.doublePoints:
        _disc(c + Offset(-u * 0.45, 0), u * 0.55, w, segs: 10);
        _disc(c + Offset(u * 0.45, 0), u * 0.55, w, segs: 10);
        _disc(c + Offset(u * 0.45, 0), u * 0.3, _fog(col, z), segs: 8);
      case PowerKind.superJump: // Pfeil nach oben
        _quad(c + Offset(0, -u * 1.1), c + Offset(u, 0), c + Offset(u * 0.55, u * 0.2),
            c + Offset(0, -u * 0.5), w);
        _quad(c + Offset(0, -u * 1.1), c + Offset(0, -u * 0.5), c + Offset(-u * 0.55, u * 0.2),
            c + Offset(-u, 0), w);
        _quad(c + Offset(-u * 0.25, -u * 0.4), c + Offset(u * 0.25, -u * 0.4),
            c + Offset(u * 0.25, u), c + Offset(-u * 0.25, u), w);
    }
  }

  // ------------------------------------------------------------------ Tore

  static const List<String> _letters = ['A', 'B', 'C'];
  static const List<int> _gateColors = [0xFF29B6F6, 0xFFAB47BC, 0xFF26A69A];

  List<TextPainter> _gateTexts(Gate g) {
    final cached = g.renderCache;
    if (cached is List<TextPainter>) return cached;
    final list = <TextPainter>[];
    final longest = g.answers.fold<int>(0, (m, a) => max(m, a.length));
    final answerSize = longest > 90 ? 22.0 : (longest > 44 ? 27.0 : 34.0);
    for (var i = 0; i < 3; i++) {
      final tp = TextPainter(
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
        maxLines: longest > 44 ? 6 : 4,
        ellipsis: '…',
        text: TextSpan(children: [
          TextSpan(
              text: '${_letters[i]}\n',
              style: const TextStyle(
                  fontSize: 46, fontWeight: FontWeight.w900, color: Colors.white, height: 1.0)),
          TextSpan(
              text: g.answers[i],
              style: TextStyle(
                  fontSize: answerSize,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  height: 1.1)),
        ]),
      )..layout(maxWidth: 380);
      list.add(tp);
    }
    g.renderCache = list;
    return list;
  }

  void _drawGate(Gate g, double z) {
    final texts = _gateTexts(g);
    final fogT = _fogT(z);
    for (var i = 0; i < 3; i++) {
      final lx = (i - 1) * kLaneWidth;
      var col = _gateColors[i];
      if (g.chosen != null) {
        if (i == g.correctIndex) {
          col = 0xFF00E676;
        } else if (i == g.chosen) {
          col = 0xFFFF1744;
        } else {
          col = 0xFF616161;
        }
      }
      // Pfosten
      for (final s in const [-1.02, 1.02]) {
        _box(lx + s - 0.09, lx + s + 0.09, 0, 4.1, z, z + 0.2, 0xFFCFD8DC);
      }
      if (z - _camZ < 0.4) continue;
      // Energiefeld
      final glow = 0.16 + 0.06 * sin(game.time * 6 + i);
      final fieldCol = _alpha(_mix(col, _fogColor, fogT), glow);
      _b.quad(_p(lx - 0.95, 0.05, z + 0.1), _p(lx + 0.95, 0.05, z + 0.1),
          _p(lx + 0.95, 2.55, z + 0.1), _p(lx - 0.95, 2.55, z + 0.1), fieldCol, fieldCol,
          fieldCol & 0x00FFFFFF, fieldCol & 0x00FFFFFF);
      // Schild
      _box(lx - 1.08, lx + 1.08, 2.6, 4.15, z, z + 0.18, _shade(col, 0.55));
      final tl = _p(lx - 1.02, 4.08, z), br = _p(lx + 1.02, 2.66, z);
      final rect = Rect.fromPoints(tl, br);
      _quad(rect.topLeft, rect.topRight, rect.bottomRight, rect.bottomLeft,
          _mix(_shade(col, 0.7), _fogColor, fogT));
      final bw = max(1.0, rect.width * 0.02);
      final bc = _mix(col, _fogColor, fogT);
      _line(rect.topLeft, rect.topRight, bw, bc);
      _line(rect.topRight, rect.bottomRight, bw, bc);
      _line(rect.bottomRight, rect.bottomLeft, bw, bc);
      _line(rect.bottomLeft, rect.topLeft, bw, bc);
      if (rect.width < 24) continue;
      // Text braucht einen echten Canvas-Aufruf: vorher Dreiecke zeichnen.
      final c = canvas!;
      _b.flush(c);
      final tp = texts[i];
      final s = (rect.width * 0.92) / 400;
      final scaleFit = min(s, (rect.height * 0.92) / tp.height);
      c.save();
      c.translate(rect.center.dx, rect.top + rect.height / 2);
      c.scale(scaleFit);
      tp.paint(c, Offset(-tp.width / 2, -tp.height / 2));
      c.restore();
      if (fogT > 0.05) {
        _quad(rect.topLeft, rect.topRight, rect.bottomRight, rect.bottomLeft,
            _alpha(_fogColor, fogT));
      }
    }
  }

  // ---------------------------------------------------------------- Spieler

  void _drawPlayer() {
    final g = game;
    if (g.invuln > 0 && g.phase == Phase.running && (g.time * 14).floor().isOdd) {
      return;
    }
    final x = g.px;
    final y = g.py;
    // Schatten
    final sp = _p(x, 0.02, 0);
    final sr = _scale(0) * 0.5 * (1 - min(g.py, 3) * 0.12);
    _fan(sp, sr, sr * 0.28, 0x73000000, 0x00000000, segs: 16);

    if (g.rolling) {
      _drawRollBall(x, y);
    } else {
      _drawRunner(x, y);
    }

    if (g.has(PowerKind.shield)) {
      final c = _p(x, y + (g.rolling ? 0.5 : 0.95), 0);
      final r = _scale(0) * (g.rolling ? 0.75 : 1.15);
      final pulse = 0.85 + 0.15 * sin(g.time * 8);
      final (co, si) = _circle(28);
      for (var i = 0; i < 28; i++) {
        final a = Offset(c.dx + co[i] * r, c.dy + si[i] * r * 1.05);
        final b = Offset(c.dx + co[i + 1] * r, c.dy + si[i + 1] * r * 1.05);
        _b.tri(c, a, b, 0x1040C4FF, _alpha(0xFF80D8FF, 0.55 * pulse),
            _alpha(0xFF80D8FF, 0.55 * pulse));
      }
    }
  }

  void _drawRunner(double x, double y) {
    final g = game;
    final look = g.look;
    final parts = <_Part>[];
    final swing = g.phase == Phase.running || g.phase == Phase.countdown ? sin(g.runPhase) : 0.0;
    final lean = g.lean.clamp(-0.35, 0.35);
    final air = g.airborne;
    final legSwing = air ? 0.0 : swing * 0.42;
    final legTop = y + 0.8;
    final legBottom = air ? y + 0.3 : y;
    for (final side in const [-1.0, 1.0]) {
      final dz = legSwing * side;
      final lift = air ? 0.0 : max(0.0, -dz) * 0.35;
      parts.add(_Part(x + side * 0.15 - 0.11, x + side * 0.15 + 0.11, legBottom + 0.12 + lift,
          legTop, dz - 0.11, dz + 0.11, look.pants));
      parts.add(_Part(x + side * 0.15 - 0.12, x + side * 0.15 + 0.12, legBottom + lift,
          legBottom + 0.14 + lift, dz - 0.13, dz + 0.17, look.shoes));
    }
    final bx = x + lean * 0.5;
    parts.add(_Part(bx - 0.32, bx + 0.32, y + 0.76, y + 1.44, -0.17, 0.17, look.hoodie,
        torso: true));
    parts.add(_Part(bx - 0.25, bx + 0.25, y + 0.86, y + 1.36, -0.38, -0.17, look.pack,
        torso: true));
    for (final side in const [-1.0, 1.0]) {
      final dz = air ? -0.1 : -swing * 0.35 * side;
      final armTop = air ? y + 1.62 : y + 1.4;
      parts.add(_Part(bx + side * 0.42 - 0.08, bx + side * 0.42 + 0.08, armTop - 0.58, armTop,
          dz - 0.08, dz + 0.08, look.hoodie));
      parts.add(_Part(bx + side * 0.42 - 0.07, bx + side * 0.42 + 0.07, armTop - 0.7,
          armTop - 0.56, dz - 0.07, dz + 0.07, look.skin));
    }
    final hx = x + lean;
    parts.add(_Part(hx - 0.2, hx + 0.2, y + 1.46, y + 1.84, -0.18, 0.18, look.skin));
    parts.add(_Part(hx - 0.22, hx + 0.22, y + 1.7, y + 1.92, -0.2, 0.2, look.hair));
    switch (look.accessory) {
      case Accessory.cap: // Kappe verkehrt herum, Schirm zeigt zur Kamera
        parts.add(_Part(hx - 0.23, hx + 0.23, y + 1.84, y + 1.98, -0.21, 0.21, look.accessoryColor));
        parts.add(_Part(hx - 0.16, hx + 0.16, y + 1.82, y + 1.87, -0.42, -0.2, look.accessoryColor));
      case Accessory.beanie:
        parts.add(_Part(hx - 0.23, hx + 0.23, y + 1.78, y + 2.04, -0.21, 0.21, look.accessoryColor));
        parts.add(_Part(hx - 0.07, hx + 0.07, y + 2.04, y + 2.12, -0.07, 0.07, _shade(look.accessoryColor, 1.3)));
      case Accessory.headphones:
        parts.add(_Part(hx - 0.27, hx - 0.19, y + 1.55, y + 1.78, -0.09, 0.09, look.accessoryColor));
        parts.add(_Part(hx + 0.19, hx + 0.27, y + 1.55, y + 1.78, -0.09, 0.09, look.accessoryColor));
        parts.add(_Part(hx - 0.24, hx + 0.24, y + 1.92, y + 1.97, -0.04, 0.04, 0xFF212121));
      case Accessory.crown:
        parts.add(_Part(hx - 0.2, hx + 0.2, y + 1.92, y + 2.02, -0.18, 0.18, look.accessoryColor));
        for (final cx in const [-0.15, 0.0, 0.15]) {
          parts.add(_Part(hx + cx - 0.04, hx + cx + 0.04, y + 2.02, y + 2.12, -0.04, 0.04,
              look.accessoryColor));
        }
      case Accessory.none:
        break;
    }
    parts.sort((a, b) => ((b.z0 + b.z1) - (a.z0 + a.z1)).sign.toInt());
    for (final p in parts) {
      _box(p.x0, p.x1, p.y0, p.y1, p.z0, p.z1, p.color);
      if (p.torso) _hoodiePattern(p, look);
    }
  }

  /// Muster auf dem Rücken (zur Kamera gewandte Seite des Hoodies).
  void _hoodiePattern(_Part p, PlayerLook look) {
    if (look.pattern == Pattern.plain) return;
    final z = p.z0 - 0.002;
    final c = look.patternColor;
    void rect(double x0, double x1, double y0, double y1) =>
        _quad(_p(x0, y0, z), _p(x1, y0, z), _p(x1, y1, z), _p(x0, y1, z), c);
    final w = p.x1 - p.x0, h = p.y1 - p.y0;
    switch (look.pattern) {
      case Pattern.stripes:
        rect(p.x0, p.x1, p.y0 + h * 0.55, p.y0 + h * 0.66);
        rect(p.x0, p.x1, p.y0 + h * 0.32, p.y0 + h * 0.40);
      case Pattern.camo:
        rect(p.x0 + w * 0.05, p.x0 + w * 0.35, p.y0 + h * 0.6, p.y0 + h * 0.85);
        rect(p.x0 + w * 0.55, p.x0 + w * 0.9, p.y0 + h * 0.45, p.y0 + h * 0.7);
        rect(p.x0 + w * 0.2, p.x0 + w * 0.5, p.y0 + h * 0.1, p.y0 + h * 0.35);
        rect(p.x0 + w * 0.65, p.x0 + w * 0.85, p.y0 + h * 0.05, p.y0 + h * 0.25);
      case Pattern.binary: // kleines Pixelgitter wie Binärcode
        for (var r = 0; r < 4; r++) {
          for (var k = 0; k < 5; k++) {
            if (_hash(r * 7 + k * 13 + (game.time * 4).floor()) < 0.5) continue;
            final x0 = p.x0 + w * (0.08 + k * 0.18), y0 = p.y0 + h * (0.12 + r * 0.2);
            rect(x0, x0 + w * 0.1, y0, y0 + h * 0.12);
          }
        }
      case Pattern.plain:
        break;
    }
  }

  /// Echte Rolle: Die Figur wird zur Kugel und überschlägt sich nach vorne.
  void _drawRollBall(double x, double y) {
    final g = game;
    final look = g.look;
    final t = (1 - g.rollTimer / kRollTime).clamp(0.0, 1.0);
    // Ein- und Ausrollen: kurz zusammenstauchen bzw. aufgehen
    final grow = t < 0.12 ? 0.75 + t / 0.12 * 0.25 : (t > 0.88 ? 1 + (t - 0.88) / 0.12 * 0.15 : 1.0);
    final rad = 0.46 * grow;
    final cy = y + rad;
    final eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2;
    final th = eased * pi * 2.0 * 1.25; // 1¼ Überschläge

    // Punkt auf der Kugeloberfläche (lokal), dreht um die x-Achse nach vorne
    (Offset, double) surf(double lx, double ly, double lz) {
      final ry = ly * cos(th) - lz * sin(th);
      final rz = ly * sin(th) + lz * cos(th);
      return (_p(x + lx, cy + ry, rz), rz);
    }

    final center = _p(x, cy, 0);
    final rpx = _scale(0) * rad;

    // Körperteile auf der Kugel: Kopf, Füße, Hände, Rucksack
    final feats = <(double, void Function())>[];
    void blob(double lx, double ly, double lz, double r, int col) {
      final (o, rz) = surf(lx, ly, lz);
      feats.add((rz, () => _fan(o, _scale(rz) * r, _scale(rz) * r, _shade(col, 1.12), col, segs: 12)));
    }

    blob(0, rad * 0.9, 0.12, 0.2, look.skin); // Kopf
    blob(0, rad * 0.98, 0.02, 0.16, look.hair); // Haare
    for (final s in const [-1.0, 1.0]) {
      blob(s * 0.16, -rad * 0.85, 0.15, 0.12, look.shoes); // Füße
      blob(s * 0.3, rad * 0.1, rad * 0.75, 0.09, look.skin); // Hände halten die Knie
    }
    blob(0, 0.05, -rad * 0.95, 0.17, look.pack); // Rucksack

    // Hinten liegende Teile zuerst (werden teilweise verdeckt)
    feats.sort((a, b) => b.$1.compareTo(a.$1));
    for (final f in feats) {
      if (f.$1 > 0) f.$2();
    }

    // Kugel mit Schattierung (Licht von oben links)
    final (co, si) = _circle(24);
    final hi = _shade(look.hoodie, 1.25), lo = _shade(look.hoodie, 0.6);
    for (var i = 0; i < 24; i++) {
      final a = Offset(center.dx + co[i] * rpx, center.dy + si[i] * rpx);
      final b = Offset(center.dx + co[i + 1] * rpx, center.dy + si[i + 1] * rpx);
      final la = (si[i] * 0.7 + co[i] * 0.3 + 1) / 2;
      final lb = (si[i + 1] * 0.7 + co[i + 1] * 0.3 + 1) / 2;
      _b.tri(center, a, b, look.hoodie, _mix(hi, lo, la), _mix(hi, lo, lb));
    }

    // Zwei Ringe (Hoodie-Bündchen und Rucksackgurt) zeigen die Drehung
    void ring(double phase, int col, double width) {
      Offset? prev;
      for (var i = 0; i <= 20; i++) {
        final phi = i / 20 * pi * 2;
        final lx = rad * 1.005 * cos(phi);
        final ly = rad * 1.005 * sin(phi) * cos(phase);
        final lz = rad * 1.005 * sin(phi) * sin(phase);
        final (o, rz) = surf(lx, ly, lz);
        if (rz > 0.02) {
          prev = null;
          continue;
        }
        if (prev != null) _line(prev, o, width, col);
        prev = o;
      }
    }

    final lw = max(2.0, rpx * 0.16);
    ring(0, look.pattern == Pattern.plain ? _shade(look.hoodie, 0.55) : look.patternColor, lw);
    ring(pi / 2, look.pack, lw * 0.8);

    // Glanzpunkt
    _fan(center + Offset(-rpx * 0.35, -rpx * 0.4), rpx * 0.28, rpx * 0.22, 0x55FFFFFF,
        0x00FFFFFF, segs: 10);

    // Vorne liegende Teile
    for (final f in feats) {
      if (f.$1 <= 0) f.$2();
    }

    // Tempo-Striche hinter der Kugel
    final sl = _alpha(0xFFFFFFFF, 0.35 * (1 - (t - 0.5).abs() * 2).clamp(0.0, 1.0));
    for (final dx in const [-0.3, 0.0, 0.3]) {
      final a = _p(x + dx, cy + rad * 0.2 - dx.abs() * 0.3, -0.6);
      final b = _p(x + dx * 1.2, cy + rad * 0.2 - dx.abs() * 0.3, -1.6);
      _line(a, b, max(1.5, rpx * 0.05), sl);
    }
  }

  void _drawParticle(Particle p, double z) {
    if (z < -2.5) return; // hinter der Figur: würde riesig vor der Kamera
    final pos = _p(p.x, p.y, z);
    final a = (p.life / p.maxLife).clamp(0.0, 1.0);
    final r = min(_h * 0.02, max(1.0, _scale(z) * p.size));
    _disc(pos, r, _alpha(p.color, a), segs: r > 6 ? 10 : 6);
  }

  void _drawVignette() {
    final c = Offset(_cx, _h * 0.5);
    final r = max(_w, _h) * 0.75;
    final (co, si) = _circle(24);
    for (var i = 0; i < 24; i++) {
      final i0 = c + Offset(co[i], si[i]) * (r * 0.6);
      final i1 = c + Offset(co[i + 1], si[i + 1]) * (r * 0.6);
      final o0 = c + Offset(co[i], si[i]) * r;
      final o1 = c + Offset(co[i + 1], si[i + 1]) * r;
      _b.quad(i0, i1, o1, o0, 0x00000000, 0x00000000, 0x88000000, 0x88000000);
    }
  }

  @override
  bool shouldRepaint(covariant RunnerPainter oldDelegate) => true;
}

class _Item {
  _Item(this.depth, this.draw);
  final double depth;
  final void Function() draw;
}

class _Part {
  _Part(this.x0, this.x1, this.y0, this.y1, this.z0, this.z1, this.color, {this.torso = false});
  final double x0, x1, y0, y1, z0, z1;
  final int color;
  final bool torso;
}
