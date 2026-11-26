import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter/foundation.dart';

import 'audio/sound.dart';
import 'data/account.dart';
import 'data/progress.dart';
import 'data/question_bank.dart';
import 'game/quality.dart';
import 'game/sky.dart';
import 'screens/account_screen.dart';
import 'screens/menu_screen.dart';
import 'ui.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final progress = await Progress.load();
  final bank = await QuestionBank.load(customJson: progress.customQuestionsJson)
    ..includeCards = progress.includeCards
    ..ap2Track = progress.ap2Track;
  await progress.ensureQuests(bank.topics(null));
  await SkyStore.apply(progress);
  await Account.instance.init(progress);
  QualityGovernor.instance
    ..setMode(progress.quality)
    ..start();
  runApp(LernspielApp(bank: bank, progress: progress));
  // Audio im Hintergrund vorbereiten, das Menü erscheint sofort.
  Sound.instance.init(progress);
}

final GlobalKey<NavigatorState> appNavigator = GlobalKey<NavigatorState>();

class LernspielApp extends StatefulWidget {
  const LernspielApp({super.key, required this.bank, required this.progress});

  final QuestionBank bank;
  final Progress progress;

  @override
  State<LernspielApp> createState() => _LernspielAppState();
}

class _LernspielAppState extends State<LernspielApp> {
  int _generation = 0;
  late final AppLifecycleListener _life;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_globalKeys);
    // Beim Minimieren/Schließen den Spielstand ins Konto sichern
    _life = AppLifecycleListener(
      onHide: Account.instance.upload,
      onDetach: Account.instance.upload,
    );
    Account.instance.onRestored = _onRestored;
    WidgetsBinding.instance.addPostFrameCallback((_) => _startupSync());
  }

  Future<void> _startupSync() async {
    if (kIsWeb) {
      // Link aus Bestätigungs- oder Passwort-Mail?
      final result = await Account.instance.handleLinkToken(Uri.base.fragment);
      if (result != null) {
        if (result == 'confirmed') await Account.instance.syncOnStart();
        appNavigator.currentState?.push(MaterialPageRoute<void>(
          builder: (_) => AccountScreen(progress: widget.progress, recoveryMode: result == 'recovery'),
        ));
        return;
      }
    }
    await Account.instance.syncOnStart();
  }

  /// Spielstand aus der Cloud wurde geladen: alles neu einlesen.
  Future<void> _onRestored() async {
    final p = widget.progress;
    widget.bank
      ..includeCards = p.includeCards
      ..ap2Track = p.ap2Track;
    await SkyStore.apply(p);
    await p.ensureQuests(widget.bank.topics(null));
    if (mounted) setState(() => _generation++);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_globalKeys);
    _life.dispose();
    super.dispose();
  }

  /// F11 oder Alt+Enter schaltet überall Vollbild um.
  bool _globalKeys(KeyEvent e) {
    if (e is! KeyDownEvent) return false;
    Sound.instance.userInteracted();
    final alt = HardwareKeyboard.instance.isAltPressed;
    if (e.logicalKey == LogicalKeyboardKey.f11 ||
        (alt && e.logicalKey == LogicalKeyboardKey.enter)) {
      AppWindow.toggleFullscreen();
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fachinformatiker Lernspiel',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      navigatorKey: appNavigator,
      builder: (context, child) => Listener(
        onPointerDown: (_) => Sound.instance.userInteracted(),
        child: child,
      ),
      home: MenuScreen(
          key: ValueKey(_generation), bank: widget.bank, progress: widget.progress),
    );
  }
}
