import 'package:flutter/material.dart';

import '../data/account.dart';
import '../data/progress.dart';
import '../ui.dart';

/// Konto anlegen / anmelden. Der Spielstand wird dann auf allen Geräten
/// synchronisiert (Windows, Mac, Linux, Android, Browser).
class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key, required this.progress, this.recoveryMode = false});
  final Progress progress;

  /// Nach Klick auf den Link aus der „Passwort vergessen“-Mail.
  final bool recoveryMode;

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final _email = TextEditingController();
  final _pw = TextEditingController();
  final _pw2 = TextEditingController();
  bool _register = false;
  bool _working = false;
  String? _error;
  String? _info;

  Account get a => Account.instance;

  @override
  void dispose() {
    _email.dispose();
    _pw.dispose();
    _pw2.dispose();
    super.dispose();
  }

  bool get _hasLocalProgress {
    final p = widget.progress;
    return p.xp > 0 || p.totalCoins > 0 || p.masteredCount(const []) > 0 || p.learnedCount > 0;
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    final pw = _pw.text;
    if (!email.contains('@') || !email.contains('.')) {
      setState(() => _error = 'Bitte eine gültige E-Mail eingeben.');
      return;
    }
    if (pw.length < 8) {
      setState(() => _error = 'Das Passwort braucht mindestens 8 Zeichen.');
      return;
    }
    if (_register && pw != _pw2.text) {
      setState(() => _error = 'Die Passwörter stimmen nicht überein.');
      return;
    }
    setState(() {
      _working = true;
      _error = null;
      _info = null;
    });
    final res = _register ? await a.signup(email, pw) : await a.login(email, pw);
    if (!mounted) return;
    if (res == 'confirm') {
      setState(() {
        _working = false;
        _register = false;
        _info = 'Fast fertig! Wir haben dir eine Mail geschickt. Klick auf den Link darin '
            'und melde dich danach hier an.';
      });
      return;
    }
    if (res != null) {
      setState(() {
        _working = false;
        _error = res;
      });
      return;
    }
    await _afterLogin();
  }

  /// Nach dem Anmelden: Online-Stand laden oder diesen Stand hochladen.
  Future<void> _afterLogin() async {
    final remote = await a.hasRemote();
    if (!mounted) return;
    if (remote == true && _hasLocalProgress) {
      final choice = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (c) => AlertDialog(
          title: const Text('Welcher Spielstand soll gelten?'),
          content: const Text(
              'In deinem Konto ist schon ein Spielstand gespeichert, und auf diesem Gerät gibt es auch einen.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c, 'up'),
                child: const Text('Diesen Gerät-Stand ins Konto laden')),
            FilledButton(
                onPressed: () => Navigator.pop(c, 'down'),
                child: const Text('Konto-Spielstand übernehmen')),
          ],
        ),
      );
      if (choice == 'up') {
        await a.upload();
      } else {
        await a.download();
      }
    } else if (remote == true) {
      await a.download();
    } else {
      await a.upload();
    }
    if (!mounted) return;
    setState(() {
      _working = false;
      _info = 'Angemeldet. Dein Spielstand ist synchronisiert.';
    });
  }

  Future<void> _forgot() async {
    final email = _email.text.trim();
    if (!email.contains('@')) {
      setState(() => _error = 'Gib oben deine E-Mail ein, dann nochmal klicken.');
      return;
    }
    final res = await a.recover(email);
    if (!mounted) return;
    setState(() {
      _error = res;
      _info = res == null ? 'Mail zum Zurücksetzen ist unterwegs. Den Link am besten am PC/Handy im Browser öffnen.' : null;
    });
  }

  Future<void> _setNewPassword() async {
    if (_pw.text.length < 8 || _pw.text != _pw2.text) {
      setState(() => _error = 'Mindestens 8 Zeichen, beide Felder gleich.');
      return;
    }
    final res = await a.changePassword(_pw.text);
    if (!mounted) return;
    setState(() {
      _error = res;
      _info = res == null ? 'Neues Passwort gespeichert.' : null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1020),
      appBar: AppBar(title: const Text('Konto & Sync'), backgroundColor: Colors.transparent),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              ValueListenableBuilder<int>(
                valueListenable: a.changed,
                builder: (_, __, ___) => a.loggedIn ? _loggedInView() : _loginView(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _status() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(_error!, style: const TextStyle(color: kBad, fontWeight: FontWeight.w600)),
          ),
        if (_info != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(_info!, style: const TextStyle(color: kGood, fontWeight: FontWeight.w600)),
          ),
      ]);

  Widget _loggedInView() {
    final last = a.lastSync;
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Icon(Icons.cloud_done, color: kGood, size: 48),
        const SizedBox(height: 8),
        Text(a.email ?? '', textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
        const SizedBox(height: 4),
        Text(
            last == null
                ? 'Noch nicht synchronisiert'
                : 'Zuletzt synchronisiert: ${last.day}.${last.month}. ${last.hour}:${last.minute.toString().padLeft(2, '0')} Uhr',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white60)),
        if (a.lastError != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(a.lastError!, textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFFFFAB40))),
          ),
        const SizedBox(height: 14),
        const Text(
            'Dein Spielstand (Münzen, XP, Skins, Lernfortschritt, Quests) wird nach jedem Lauf automatisch gespeichert. '
            'Melde dich auf einem anderen Gerät mit derselben E-Mail an – dort geht es genau hier weiter.',
            style: TextStyle(color: Colors.white70)),
        if (widget.recoveryMode) ...[
          const SizedBox(height: 16),
          const Text('Neues Passwort festlegen', style: TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          TextField(controller: _pw, obscureText: true,
              decoration: const InputDecoration(labelText: 'Neues Passwort', border: OutlineInputBorder())),
          const SizedBox(height: 8),
          TextField(controller: _pw2, obscureText: true,
              decoration: const InputDecoration(labelText: 'Wiederholen', border: OutlineInputBorder())),
          const SizedBox(height: 8),
          FilledButton(onPressed: _setNewPassword, child: const Text('Passwort speichern')),
        ],
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: a.busy
              ? null
              : () async {
                  await a.upload();
                  if (mounted) setState(() {});
                },
          icon: const Icon(Icons.cloud_upload),
          label: const Text('Jetzt speichern'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (c) => AlertDialog(
                title: const Text('Online-Spielstand laden?'),
                content: const Text('Der Spielstand auf diesem Gerät wird durch den Konto-Spielstand ersetzt.'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Abbrechen')),
                  FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Laden')),
                ],
              ),
            );
            if (ok == true) await a.download();
            if (mounted) setState(() {});
          },
          icon: const Icon(Icons.cloud_download),
          label: const Text('Spielstand aus dem Konto laden'),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: () async {
            await a.upload();
            await a.logout();
          },
          icon: const Icon(Icons.logout),
          label: const Text('Abmelden'),
        ),
        _status(),
      ]),
    );
  }

  Widget _loginView() {
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Icon(Icons.account_circle, color: kAccent, size: 48),
        const SizedBox(height: 6),
        Text(_register ? 'Konto erstellen' : 'Anmelden',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
        const SizedBox(height: 4),
        const Text('Mit einem Konto spielst du auf jedem Gerät mit deinem Spielstand weiter.',
            textAlign: TextAlign.center, style: TextStyle(color: Colors.white60)),
        const SizedBox(height: 16),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Anmelden')),
            ButtonSegment(value: true, label: Text('Registrieren')),
          ],
          selected: {_register},
          onSelectionChanged: (v) => setState(() {
            _register = v.first;
            _error = null;
          }),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          decoration: const InputDecoration(labelText: 'E-Mail', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _pw,
          obscureText: true,
          autofillHints: [_register ? AutofillHints.newPassword : AutofillHints.password],
          decoration: const InputDecoration(
              labelText: 'Passwort (mind. 8 Zeichen)', border: OutlineInputBorder()),
          onSubmitted: (_) => _register ? null : _submit(),
        ),
        if (_register) ...[
          const SizedBox(height: 10),
          TextField(
            controller: _pw2,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Passwort wiederholen', border: OutlineInputBorder()),
            onSubmitted: (_) => _submit(),
          ),
        ],
        const SizedBox(height: 14),
        FilledButton(
          style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
          onPressed: _working ? null : _submit,
          child: _working
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(_register ? 'Konto erstellen' : 'Anmelden'),
        ),
        if (!_register)
          TextButton(onPressed: _forgot, child: const Text('Passwort vergessen?')),
        _status(),
      ]),
    );
  }
}
