import 'dart:math';
import 'dart:typed_data';

/// Kleiner Software-Synthesizer: erzeugt Musik und Soundeffekte als WAV.
/// So braucht das Spiel keine großen Audiodateien (kleine EXE).
const int kRate = 22050;

double _midiHz(num m) => 440.0 * pow(2, (m - 69) / 12);

class _Buf {
  _Buf(double seconds) : data = Float64List((seconds * kRate).ceil());
  final Float64List data;
  int get length => data.length;

  void add(int i, double v) {
    if (i >= 0 && i < data.length) data[i] += v;
  }
}

double _square(double ph, [double duty = 0.5]) => (ph % 1.0) < duty ? 1.0 : -1.0;
double _saw(double ph) => 2.0 * (ph % 1.0) - 1.0;
double _tri(double ph) => 1.0 - 4.0 * ((ph % 1.0) - 0.5).abs();

/// Ein Ton mit einfacher ADSR-Hüllkurve.
void _note(_Buf b, double start, double dur, double hz, double vol,
    {String wave = 'square',
    double duty = 0.5,
    double attack = 0.005,
    double release = 0.06,
    double slideTo = 0,
    double vibrato = 0}) {
  final s0 = (start * kRate).round();
  final n = ((dur + release) * kRate).round();
  var ph = 0.0;
  for (var i = 0; i < n; i++) {
    final t = i / kRate;
    var f = slideTo > 0 ? hz + (slideTo - hz) * min(1.0, t / dur) : hz;
    if (vibrato > 0 && t > 0.08) f *= 1 + sin(t * 2 * pi * 5.5) * vibrato;
    ph += f / kRate;
    final env = t < attack
        ? t / attack
        : (t < dur ? 1.0 - 0.25 * (t - attack) / max(dur, 0.001) : max(0.0, 0.75 * (1 - (t - dur) / release)));
    final v = switch (wave) {
      'saw' => _saw(ph),
      'tri' => _tri(ph),
      'sine' => sin(ph * 2 * pi),
      _ => _square(ph, duty),
    };
    b.add(s0 + i, v * env * vol);
  }
}

void _kick(_Buf b, double start, double vol) {
  final s0 = (start * kRate).round();
  var ph = 0.0;
  for (var i = 0; i < kRate * 0.22; i++) {
    final t = i / kRate;
    ph += (48 + 110 * exp(-t * 28)) / kRate;
    b.add(s0 + i, sin(ph * 2 * pi) * exp(-t * 14) * vol);
  }
}

void _noise(_Buf b, Random r, double start, double dur, double vol, {double decay = 30, double hp = 0}) {
  final s0 = (start * kRate).round();
  var last = 0.0;
  for (var i = 0; i < dur * kRate; i++) {
    final t = i / kRate;
    final w = r.nextDouble() * 2 - 1;
    final v = hp > 0 ? w - last * hp : w; // grober Hochpass
    last = w;
    b.add(s0 + i, v * exp(-t * decay) * vol);
  }
}

Uint8List _toWav(_Buf b, {double gain = 0.9}) {
  var peak = 0.0001;
  for (final v in b.data) {
    peak = max(peak, v.abs());
  }
  final k = gain / peak;
  final n = b.length;
  final bytes = ByteData(44 + n * 2);
  void str(int o, String s) {
    for (var i = 0; i < s.length; i++) {
      bytes.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  bytes.setUint32(4, 36 + n * 2, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, kRate, Endian.little);
  bytes.setUint32(28, kRate * 2, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  str(36, 'data');
  bytes.setUint32(40, n * 2, Endian.little);
  for (var i = 0; i < n; i++) {
    // weiches Clipping
    final v = b.data[i] * k;
    final c = v.abs() < 1 ? v : v.sign;
    bytes.setInt16(44 + i * 2, (c * 32000).round(), Endian.little);
  }
  return bytes.buffer.asUint8List();
}

// ------------------------------------------------------------------- Musik

/// Synthwave-Loop fürs Rennen (128 BPM, a-Moll, 16 Takte).
Uint8List makeRunTrack() {
  const bpm = 128.0;
  const beat = 60 / bpm;
  const bars = 16;
  final b = _Buf(bars * 4 * beat + 0.3);
  final r = Random(11);
  // Am – F – C – G
  const roots = [57, 53, 48, 55];
  const chords = [
    [57, 60, 64],
    [53, 57, 60],
    [48, 52, 55],
    [55, 59, 62],
  ];
  const penta = [69, 72, 74, 76, 79, 81, 84];
  final melody = <int>[];
  var idx = 3;
  for (var i = 0; i < 32; i++) {
    idx = (idx + r.nextInt(3) - 1).clamp(0, penta.length - 1);
    melody.add(penta[idx]);
  }
  for (var bar = 0; bar < bars; bar++) {
    final ci = bar % 4;
    final t0 = bar * 4 * beat;
    final section = bar ~/ 4; // 0: Intro, 1: Groove, 2: Melodie, 3: Melodie + mehr
    for (var q = 0; q < 4; q++) {
      final t = t0 + q * beat;
      if (section > 0 || q % 2 == 0) _kick(b, t, 0.9);
      if (q % 2 == 1 && section > 0) _noise(b, r, t, 0.18, 0.35, decay: 18);
      _noise(b, r, t + beat / 2, 0.05, 0.12, decay: 80, hp: 0.9);
      if (section >= 2) _noise(b, r, t, 0.04, 0.07, decay: 90, hp: 0.9);
    }
    // Bass: Achtel, Grundton/Oktave
    for (var e = 0; e < 8; e++) {
      final m = roots[ci] - 24 + (e % 2 == 1 ? 12 : 0);
      _note(b, t0 + e * beat / 2, beat / 2 * 0.8, _midiHz(m), 0.34, wave: 'saw', release: 0.03);
    }
    // Arpeggio: Sechzehntel
    for (var s = 0; s < 16; s++) {
      final ch = chords[ci];
      final m = ch[s % 3] + (s % 6 >= 3 ? 12 : 0);
      _note(b, t0 + s * beat / 4, beat / 4 * 0.6, _midiHz(m), section == 0 ? 0.12 : 0.09,
          wave: 'square', duty: 0.25, release: 0.04);
    }
    // Flächenakkord
    for (final m in chords[ci]) {
      _note(b, t0, 4 * beat * 0.95, _midiHz(m), 0.05, wave: 'tri', attack: 0.3, release: 0.4);
    }
    // Melodie ab Abschnitt 2
    if (section >= 2) {
      for (var k = 0; k < 4; k++) {
        final m = melody[(bar % 8) * 4 + k];
        final long = k == 3;
        _note(b, t0 + k * beat, beat * (long ? 0.95 : 0.7), _midiHz(m), 0.16,
            wave: 'square', duty: 0.125, vibrato: 0.006, release: 0.08);
      }
    }
  }
  return _toWav(b, gain: 0.8);
}

/// Ruhiger Loop fürs Menü (92 BPM).
Uint8List makeMenuTrack() {
  const bpm = 92.0;
  const beat = 60 / bpm;
  const bars = 8;
  final b = _Buf(bars * 4 * beat + 0.5);
  final r = Random(5);
  // Fmaj7 – Em7 – Dm7 – Cmaj7 (entspannt)
  const chords = [
    [53, 57, 60, 64],
    [52, 55, 59, 62],
    [50, 53, 57, 60],
    [48, 52, 55, 59],
  ];
  for (var bar = 0; bar < bars; bar++) {
    final ch = chords[bar % 4];
    final t0 = bar * 4 * beat;
    for (final m in ch) {
      _note(b, t0, 4 * beat, _midiHz(m), 0.07, wave: 'tri', attack: 0.5, release: 0.6);
    }
    _note(b, t0, 2 * beat, _midiHz(ch[0] - 12), 0.2, wave: 'sine', release: 0.2);
    _note(b, t0 + 2 * beat, 2 * beat, _midiHz(ch[0] - 12), 0.16, wave: 'sine', release: 0.2);
    for (var e = 0; e < 8; e++) {
      if (r.nextDouble() < 0.25) continue;
      final m = ch[r.nextInt(4)] + 12;
      _note(b, t0 + e * beat / 2, beat * 0.4, _midiHz(m), 0.06, wave: 'sine', release: 0.35);
    }
    for (var q = 0; q < 4; q++) {
      if (q == 0 || q == 2) _kick(b, t0 + q * beat, 0.35);
      _noise(b, r, t0 + q * beat + beat / 2, 0.04, 0.05, decay: 90, hp: 0.9);
    }
  }
  return _toWav(b, gain: 0.7);
}

// ------------------------------------------------------------ Soundeffekte

Uint8List makeSfx(String name) {
  final r = Random(name.hashCode);
  switch (name) {
    case 'coin':
      final b = _Buf(0.2);
      _note(b, 0, 0.05, 988, 0.5, duty: 0.25, release: 0.02);
      _note(b, 0.05, 0.09, 1319, 0.5, duty: 0.25, release: 0.05);
      return _toWav(b, gain: 0.5);
    case 'jump':
      final b = _Buf(0.25);
      _note(b, 0, 0.16, 300, 0.5, duty: 0.25, slideTo: 760, release: 0.05);
      return _toWav(b, gain: 0.45);
    case 'roll':
      final b = _Buf(0.35);
      _noise(b, r, 0, 0.3, 0.6, decay: 9, hp: 0.5);
      _note(b, 0, 0.2, 220, 0.25, wave: 'tri', slideTo: 110, release: 0.08);
      return _toWav(b, gain: 0.4);
    case 'correct':
      final b = _Buf(0.6);
      const ms = [72, 76, 79, 84];
      for (var i = 0; i < 4; i++) {
        _note(b, i * 0.07, 0.12, _midiHz(ms[i]), 0.4, duty: 0.25, release: 0.15);
        _note(b, i * 0.07, 0.12, _midiHz(ms[i] - 12), 0.15, wave: 'tri', release: 0.15);
      }
      return _toWav(b, gain: 0.6);
    case 'wrong':
      final b = _Buf(0.55);
      _note(b, 0, 0.18, 330, 0.4, wave: 'saw', slideTo: 260, release: 0.03);
      _note(b, 0.2, 0.25, 250, 0.4, wave: 'saw', slideTo: 150, release: 0.08);
      return _toWav(b, gain: 0.55);
    case 'crash':
      final b = _Buf(0.45);
      _noise(b, r, 0, 0.4, 0.8, decay: 10);
      _note(b, 0, 0.25, 120, 0.6, wave: 'sine', slideTo: 45, release: 0.1);
      return _toWav(b, gain: 0.6);
    case 'powerup':
      final b = _Buf(0.55);
      for (var i = 0; i < 8; i++) {
        _note(b, i * 0.045, 0.06, _midiHz(64 + i * 3), 0.35, duty: 0.125, release: 0.05);
      }
      return _toWav(b, gain: 0.5);
    case 'shield':
      final b = _Buf(0.4);
      _note(b, 0, 0.3, 880, 0.4, wave: 'tri', slideTo: 440, release: 0.08, vibrato: 0.03);
      _noise(b, r, 0, 0.15, 0.3, decay: 20, hp: 0.8);
      return _toWav(b, gain: 0.5);
    case 'buy':
      final b = _Buf(0.5);
      _note(b, 0, 0.06, 1047, 0.4, duty: 0.25);
      _note(b, 0.07, 0.06, 1319, 0.4, duty: 0.25);
      _note(b, 0.14, 0.2, 1568, 0.4, duty: 0.25, release: 0.15);
      return _toWav(b, gain: 0.5);
    case 'levelup':
      final b = _Buf(1.0);
      const ms = [60, 64, 67, 72, 67, 72, 76];
      for (var i = 0; i < ms.length; i++) {
        _note(b, i * 0.09, i == ms.length - 1 ? 0.35 : 0.08, _midiHz(ms[i]), 0.35,
            duty: 0.25, release: 0.2, vibrato: i == ms.length - 1 ? 0.01 : 0);
      }
      return _toWav(b, gain: 0.6);
    default: // click
      final b = _Buf(0.06);
      _note(b, 0, 0.02, 1500, 0.3, duty: 0.5, release: 0.02);
      return _toWav(b, gain: 0.3);
  }
}

const List<String> kSfxNames = [
  'coin', 'jump', 'roll', 'correct', 'wrong', 'crash', 'powerup', 'shield', 'buy', 'levelup', 'click'
];
