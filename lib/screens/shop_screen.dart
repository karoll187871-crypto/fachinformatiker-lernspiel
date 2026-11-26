import 'dart:math';

import 'package:file_picker/file_picker.dart';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../audio/sound.dart';
import '../data/cosmetics.dart';
import '../data/progress.dart';
import '../game/engine.dart';
import '../game/renderer.dart';
import '../game/sky.dart';
import '../platform.dart';
import '../ui.dart';

/// Shop: Skins, Laufspuren und Wissens-Kisten mit Münzen kaufen.
class ShopScreen extends StatefulWidget {
  const ShopScreen({super.key, required this.progress});
  final Progress progress;

  @override
  State<ShopScreen> createState() => _ShopScreenState();
}

class _Tick extends ChangeNotifier {
  void tick() => notifyListeners();
}

class _ShopScreenState extends State<ShopScreen> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _repaint = _Tick();
  Duration _last = Duration.zero;
  late RunnerGame _preview;
  String? _previewSkin;
  String? _previewTrail;
  final _rng = Random();

  Progress get p => widget.progress;

  @override
  void initState() {
    super.initState();
    _rebuildPreview();
    _ticker = createTicker((e) {
      final dt = ((e - _last).inMicroseconds / 1e6).clamp(0.0, 0.05);
      _last = e;
      _preview.update(dt);
      _repaint.tick();
    })
      ..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  void _rebuildPreview() {
    final skin = skinById(_previewSkin ?? p.skinId);
    final trail = trailById(_previewTrail ?? p.trailId);
    _preview = RunnerGame(demo: true, seed: 9, look: skin.look, trailColors: trail.colors);
  }

  void _showSkin(Skin s) => setState(() {
        _previewSkin = s.id;
        _rebuildPreview();
      });

  void _showTrail(Trail t) => setState(() {
        _previewTrail = t.id;
        _rebuildPreview();
      });

  Future<void> _skinAction(Skin s) async {
    _showSkin(s);
    final owned = p.ownedSkins.contains(s.id);
    if (owned) {
      await p.selectSkin(s.id);
      Sound.instance.play('click');
    } else {
      if (s.boxOnly || p.level < s.minLevel) return;
      if (!await p.spendCoins(s.price)) return;
      await p.unlockSkin(s.id);
      await p.selectSkin(s.id);
      Sound.instance.play('buy');
    }
    setState(() {});
  }

  Future<void> _trailAction(Trail t) async {
    _showTrail(t);
    final owned = p.ownedTrails.contains(t.id);
    if (owned) {
      await p.selectTrail(t.id);
      Sound.instance.play('click');
    } else {
      if (t.boxOnly) return;
      if (!await p.spendCoins(t.price)) return;
      await p.unlockTrail(t.id);
      await p.selectTrail(t.id);
      Sound.instance.play('buy');
    }
    setState(() {});
  }

  Future<void> _skyAction(SkyTheme t) async {
    if (t.custom && !hasFileSystem) return; // im Browser keine eigenen Dateien
    final owned = p.ownedSkies.contains(t.id);
    if (!owned) {
      if (!p.canAfford(t.price)) return;
      final yes = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text('„${t.name}“ kaufen?'),
          content: Text(t.custom
              ? 'Kostet ${t.price} Münzen. Danach wählst du ein Bild von deinem PC als Himmel – du kannst es jederzeit wechseln.'
              : 'Kostet ${t.price} Münzen.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Abbrechen')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Kaufen')),
          ],
        ),
      );
      if (yes != true || !await p.spendCoins(t.price)) return;
      await p.unlockSky(t.id);
      Sound.instance.play('buy');
    }
    if (t.custom) {
      // Eigenes Bild: (neu) auswählen
      if (p.customSkyPath == null || owned) {
        final ok = await _pickSkyImage();
        if (!ok && p.customSkyPath == null) {
          setState(() {});
          return;
        }
      }
    }
    await p.selectSky(t.id);
    await SkyStore.apply(p);
    if (owned) Sound.instance.play('click');
    if (mounted) setState(() {});
  }

  Future<bool> _pickSkyImage() async {
    final files = await FilePicker.pickFiles(
      dialogTitle: 'Bild für den Himmel auswählen',
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif'],
    );
    final path = files.isEmpty ? null : files.first.path;
    if (path == null) return false;
    final stored = await SkyStore.importImage(path);
    if (stored == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Das Bild konnte nicht geladen werden.')));
      }
      return false;
    }
    await p.setCustomSkyPath(stored);
    return true;
  }

  Widget _skyTile(SkyTheme t) {
    final owned = p.ownedSkies.contains(t.id);
    final selected = p.skyId == t.id && SkyStore.theme.id == t.id;
    String status;
    Color col;
    if (t.custom && !hasFileSystem) {
      status = 'Nur in der App';
      col = Colors.white38;
    } else if (selected) {
      status = t.custom ? 'Aktiv · Klick = neues Bild' : 'Aktiv';
      col = kAccent;
    } else if (owned) {
      status = t.custom ? 'Bild wählen' : 'Benutzen';
      col = kGood;
    } else {
      status = '${t.price} Münzen';
      col = p.canAfford(t.price) ? kGold : kBad;
    }
    final img = SkyStore.image;
    final swatch = Container(
      height: 46,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
        gradient: t.custom
            ? null
            : LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [for (final c in t.colors) Color(c)]),
      ),
      clipBehavior: Clip.antiAlias,
      child: t.custom
          ? (img != null && owned
              ? RawImage(image: img, fit: BoxFit.cover)
              : const Center(child: Icon(Icons.add_photo_alternate, color: Colors.white70)))
          : Align(
              alignment: const Alignment(0.4, 0.6),
              child: Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(t.sunTop), Color(t.sunBottom)]),
                ),
              ),
            ),
    );
    return Tooltip(
      message: t.custom
          ? 'Dein eigenes Bild als Himmel (PNG/JPG). Sehr teuer: ${t.price} Münzen.'
          : t.name,
      child: _tile(
        selected: selected,
        previewing: false,
        name: t.name,
        status: status,
        statusColor: col,
        onTap: () => _skyAction(t),
        swatch: swatch,
      ),
    );
  }

  Future<void> _openBox() async {
    if (!await p.spendCoins(kBoxPrice)) return;
    final reward = rollBox(_rng, p.ownedSkins, p.ownedTrails);
    if (reward.skin != null) await p.unlockSkin(reward.skin!.id);
    if (reward.trail != null) await p.unlockTrail(reward.trail!.id);
    if (reward.coins > 0) await p.addCoins(reward.coins);
    if (reward.xp > 0) await p.addXp(reward.xp);
    Sound.instance.play('powerup');
    if (!mounted) return;
    setState(() {});
    await showDialog<void>(
      context: context,
      builder: (c) => _BoxDialog(reward: reward),
    );
    if (!mounted) return;
    if (reward.skin != null) _showSkin(reward.skin!);
    if (reward.trail != null) _showTrail(reward.trail!);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1020),
      appBar: AppBar(
        title: const Text('Shop'),
        backgroundColor: Colors.transparent,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Row(children: [
              const Icon(Icons.monetization_on, color: kGold),
              const SizedBox(width: 6),
              Text('${p.totalCoins}',
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w900, color: kGold)),
              const SizedBox(width: 16),
              Text('Level ${p.level}',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w800, color: Color(0xFFB388FF))),
            ]),
          ),
        ],
      ),
      body: LayoutBuilder(builder: (context, c) {
        final wide = c.maxWidth > 900;
        final preview = ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: RepaintBoundary(
            child: CustomPaint(
              painter: RunnerPainter(_preview, _repaint),
              isComplex: true,
              willChange: true,
              child: const SizedBox.expand(),
            ),
          ),
        );
        final list = ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [
            _boxCard(),
            const SizedBox(height: 18),
            _header('Skins', 'Klick zum Ansehen, nochmal klicken zum Kaufen/Anziehen'),
            Wrap(spacing: 10, runSpacing: 10, children: [for (final s in kSkins) _skinTile(s)]),
            const SizedBox(height: 18),
            _header('Himmel', 'Ändert den Himmel im Spiel'),
            Wrap(spacing: 10, runSpacing: 10, children: [for (final t in kSkies) _skyTile(t)]),
            const SizedBox(height: 18),
            _header('Laufspuren', 'Effekt hinter deiner Figur'),
            Wrap(spacing: 10, runSpacing: 10, children: [for (final t in kTrails) _trailTile(t)]),
          ],
        );
        if (wide) {
          return Row(children: [
            SizedBox(
              width: c.maxWidth * 0.42,
              child: Padding(padding: const EdgeInsets.fromLTRB(16, 4, 0, 16), child: preview),
            ),
            Expanded(child: list),
          ]);
        }
        return Column(children: [
          SizedBox(
              height: c.maxHeight * 0.38,
              child: Padding(padding: const EdgeInsets.all(12), child: preview)),
          Expanded(child: list),
        ]);
      }),
    );
  }

  Widget _header(String t, String sub) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(t, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
          const SizedBox(width: 10),
          Expanded(
              child: Text(sub, style: const TextStyle(fontSize: 12, color: Colors.white54))),
        ]),
      );

  Widget _boxCard() {
    final afford = p.canAfford(kBoxPrice);
    return Panel(
      border: kGold.withValues(alpha: 0.7),
      child: Row(children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: [Color(0xFFFFD54F), Color(0xFFFF8F00)]),
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Icon(Icons.inventory_2_rounded, size: 40, color: Colors.black87),
        ),
        const SizedBox(width: 14),
        const Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Wissens-Kiste',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
            SizedBox(height: 2),
            Text(
                'Zufällig: Skin, Laufspur, XP oder Münzen. Manche Skins und Spuren gibt es nur hier.',
                style: TextStyle(fontSize: 13, color: Colors.white70)),
          ]),
        ),
        const SizedBox(width: 12),
        FilledButton.icon(
          style: FilledButton.styleFrom(
              backgroundColor: kGold,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14)),
          onPressed: afford ? _openBox : null,
          icon: const Icon(Icons.monetization_on),
          label: const Text('$kBoxPrice  Öffnen',
              style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15)),
        ),
      ]),
    );
  }

  Widget _tile({
    required bool selected,
    required bool previewing,
    required Widget swatch,
    required String name,
    required String status,
    required Color statusColor,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: 150,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: selected ? kAccent.withValues(alpha: 0.18) : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: selected ? kAccent : (previewing ? Colors.white54 : Colors.white12),
              width: selected ? 2.5 : 1.2),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          swatch,
          const SizedBox(height: 8),
          Text(name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
          const SizedBox(height: 2),
          Text(status,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: statusColor)),
        ]),
      ),
    );
  }

  Widget _skinTile(Skin s) {
    final owned = p.ownedSkins.contains(s.id);
    final selected = p.skinId == s.id;
    String status;
    Color col;
    if (selected) {
      status = 'Angezogen';
      col = kAccent;
    } else if (owned) {
      status = 'Anziehen';
      col = kGood;
    } else if (s.boxOnly) {
      status = 'Nur aus der Kiste';
      col = const Color(0xFFFF8A65);
    } else if (p.level < s.minLevel) {
      status = 'Ab Level ${s.minLevel}';
      col = Colors.white38;
    } else {
      status = '${s.price} Münzen';
      col = p.canAfford(s.price) ? kGold : kBad;
    }
    final l = s.look;
    return Tooltip(
      message: s.description.isEmpty ? s.name : s.description,
      child: _tile(
        selected: selected,
        previewing: _previewSkin == s.id,
        name: s.name,
        status: status,
        statusColor: col,
        onTap: () => _previewSkin == s.id || owned ? _skinAction(s) : _showSkin(s),
        swatch: Row(children: [
          for (final c in [l.hoodie, l.pants, l.pack, l.patternColor, l.accessoryColor])
            Container(
              width: 20,
              height: 20,
              margin: const EdgeInsets.only(right: 4),
              decoration: BoxDecoration(
                color: Color(c),
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: Colors.white24),
              ),
            ),
        ]),
      ),
    );
  }

  Widget _trailTile(Trail t) {
    final owned = p.ownedTrails.contains(t.id);
    final selected = p.trailId == t.id;
    String status;
    Color col;
    if (selected) {
      status = 'Aktiv';
      col = kAccent;
    } else if (owned) {
      status = 'Benutzen';
      col = kGood;
    } else if (t.boxOnly) {
      status = 'Nur aus der Kiste';
      col = const Color(0xFFFF8A65);
    } else {
      status = '${t.price} Münzen';
      col = p.canAfford(t.price) ? kGold : kBad;
    }
    return _tile(
      selected: selected,
      previewing: _previewTrail == t.id,
      name: t.name,
      status: status,
      statusColor: col,
      onTap: () => _previewTrail == t.id || owned ? _trailAction(t) : _showTrail(t),
      swatch: SizedBox(
        height: 20,
        child: t.colors.isEmpty
            ? const Icon(Icons.block, size: 20, color: Colors.white38)
            : Row(children: [
                for (final c in t.colors)
                  Container(
                    width: 14,
                    height: 14,
                    margin: const EdgeInsets.only(right: 4),
                    decoration: BoxDecoration(color: Color(c), shape: BoxShape.circle),
                  ),
              ]),
      ),
    );
  }
}

class _BoxDialog extends StatefulWidget {
  const _BoxDialog({required this.reward});
  final BoxReward reward;

  @override
  State<_BoxDialog> createState() => _BoxDialogState();
}

class _BoxDialogState extends State<_BoxDialog> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.reward;
    final rare = r.skin?.boxOnly == true || r.trail?.boxOnly == true || r.coins >= 1000;
    final color = rare ? const Color(0xFFFF6E40) : kGold;
    return Dialog(
      backgroundColor: kPanel,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22), side: BorderSide(color: color, width: 2)),
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final t = Curves.elasticOut.transform(_c.value);
            return Column(mainAxisSize: MainAxisSize.min, children: [
              Transform.scale(
                scale: 0.4 + 0.6 * t,
                child: Transform.rotate(
                  angle: (1 - _c.value) * pi,
                  child: Icon(
                    r.skin != null
                        ? Icons.checkroom
                        : r.trail != null
                            ? Icons.auto_awesome
                            : r.xp > 0
                                ? Icons.school
                                : Icons.monetization_on,
                    size: 90,
                    color: color,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (rare)
                Text('SELTEN!',
                    style: TextStyle(
                        color: color, fontWeight: FontWeight.w900, letterSpacing: 4)),
              Text(r.title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
              const SizedBox(height: 18),
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Nice!'),
              ),
            ]);
          },
        ),
      ),
    );
  }
}
