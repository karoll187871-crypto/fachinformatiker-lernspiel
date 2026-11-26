import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'progress.dart';

/// Konto + Cloud-Spielstand (Netlify Identity + Netlify Blobs).
/// Passwörter verarbeitet nur Netlify Identity – das Spiel speichert sie nie.
class Account {
  Account._();
  static final Account instance = Account._();

  static const String server = 'https://fachinformatiker-lernspiel.netlify.app';

  /// Im Browser immer die eigene Adresse nutzen (gleiche Herkunft).
  static String get base {
    if (kIsWeb) {
      final o = Uri.base;
      if (o.host.endsWith('netlify.app') || o.host == 'localhost') return o.origin;
    }
    return server;
  }

  late SharedPreferences _prefs;
  late Progress _progress;

  final ValueNotifier<int> changed = ValueNotifier(0);

  /// Wird aufgerufen, nachdem ein Spielstand aus der Cloud geladen wurde.
  VoidCallback? onRestored;

  String? get email => _prefs.getString('acct_email');
  bool get loggedIn => _prefs.getString('acct_refresh') != null;
  DateTime? get lastSync {
    final ms = _prefs.getInt('acct_last_sync');
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  String? lastError;
  bool busy = false;

  Future<void> init(Progress progress) async {
    _progress = progress;
    _prefs = await SharedPreferences.getInstance();
  }

  // --------------------------------------------------------------- Identity

  Uri _u(String path) => Uri.parse('$base$path');

  static String _msg(http.Response r) {
    try {
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      final m = (j['error_description'] ?? j['msg'] ?? j['error'] ?? '').toString();
      if (m.contains('already') || m.contains('registered')) {
        return 'Diese E-Mail hat schon ein Konto. Bitte anmelden.';
      }
      if (m.contains('Invalid') || m.contains('invalid_grant')) {
        return 'E-Mail oder Passwort falsch.';
      }
      if (m.contains('not confirmed') || m.contains('Email not confirmed')) {
        return 'Bitte zuerst den Link in der Bestätigungs-Mail anklicken.';
      }
      if (m.isNotEmpty) return m;
    } catch (_) {}
    if (r.statusCode == 404) {
      return 'Der Konto-Dienst ist noch nicht eingeschaltet (Netlify Identity).';
    }
    return 'Fehler ${r.statusCode}';
  }

  /// Registrieren. Rückgabe: null = sofort angemeldet,
  /// 'confirm' = Bestätigungs-Mail wurde geschickt, sonst Fehlermeldung.
  Future<String?> signup(String email, String password) async {
    try {
      final r = await http
          .post(_u('/.netlify/identity/signup'),
              headers: {'content-type': 'application/json'},
              body: jsonEncode({'email': email.trim(), 'password': password}))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode >= 300) return _msg(r);
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      if (j['confirmed_at'] == null && j['email_confirmed_at'] == null) return 'confirm';
      return await login(email, password);
    } catch (e) {
      return 'Keine Verbindung zum Server.';
    }
  }

  /// Anmelden. Rückgabe: null = ok, sonst Fehlermeldung.
  Future<String?> login(String email, String password) async {
    try {
      final r = await http.post(_u('/.netlify/identity/token'), body: {
        'grant_type': 'password',
        'username': email.trim(),
        'password': password,
      }).timeout(const Duration(seconds: 15));
      if (r.statusCode >= 300) return _msg(r);
      await _storeTokens(jsonDecode(r.body) as Map<String, dynamic>, email.trim());
      return null;
    } catch (e) {
      return 'Keine Verbindung zum Server.';
    }
  }

  /// Passwort-Mail anfordern.
  Future<String?> recover(String email) async {
    try {
      final r = await http
          .post(_u('/.netlify/identity/recover'),
              headers: {'content-type': 'application/json'},
              body: jsonEncode({'email': email.trim()}))
          .timeout(const Duration(seconds: 15));
      return r.statusCode >= 300 ? _msg(r) : null;
    } catch (_) {
      return 'Keine Verbindung zum Server.';
    }
  }

  /// Link aus einer Mail (nur Web): Bestätigung oder Passwort-Reset.
  /// Rückgabe: 'confirmed', 'recovery' oder null.
  Future<String?> handleLinkToken(String fragment) async {
    final params = Uri.splitQueryString(fragment);
    final confirm = params['confirmation_token'];
    final recovery = params['recovery_token'];
    final token = confirm ?? recovery;
    if (token == null) return null;
    try {
      final r = await http
          .post(_u('/.netlify/identity/verify'),
              headers: {'content-type': 'application/json'},
              body: jsonEncode({'token': token, 'type': confirm != null ? 'signup' : 'recovery'}))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode >= 300) return null;
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      final user = await _userInfo(j['access_token'] as String);
      await _storeTokens(j, (user?['email'] as String?) ?? '');
      return confirm != null ? 'confirmed' : 'recovery';
    } catch (_) {
      return null;
    }
  }

  Future<String?> changePassword(String password) async {
    final t = await _token();
    if (t == null) return 'Nicht angemeldet.';
    try {
      final r = await http
          .put(_u('/.netlify/identity/user'),
              headers: {'content-type': 'application/json', 'authorization': 'Bearer $t'},
              body: jsonEncode({'password': password}))
          .timeout(const Duration(seconds: 15));
      return r.statusCode >= 300 ? _msg(r) : null;
    } catch (_) {
      return 'Keine Verbindung zum Server.';
    }
  }

  Future<Map<String, dynamic>?> _userInfo(String access) async {
    final r = await http.get(_u('/.netlify/identity/user'),
        headers: {'authorization': 'Bearer $access'});
    return r.statusCode == 200 ? jsonDecode(r.body) as Map<String, dynamic> : null;
  }

  Future<void> _storeTokens(Map<String, dynamic> j, String email) async {
    final expires = (j['expires_in'] as num?)?.toInt() ?? 3600;
    await _prefs.setString('acct_access', j['access_token'] as String);
    await _prefs.setString('acct_refresh', j['refresh_token'] as String);
    await _prefs.setInt(
        'acct_exp', DateTime.now().millisecondsSinceEpoch + (expires - 60) * 1000);
    if (email.isNotEmpty) await _prefs.setString('acct_email', email);
    changed.value++;
  }

  Future<void> logout() async {
    for (final k in ['acct_access', 'acct_refresh', 'acct_exp', 'acct_email', 'acct_last_sync']) {
      await _prefs.remove(k);
    }
    changed.value++;
  }

  /// Gültigen Zugriffstoken holen (bei Bedarf erneuern).
  Future<String?> _token() async {
    final access = _prefs.getString('acct_access');
    final refresh = _prefs.getString('acct_refresh');
    if (refresh == null) return null;
    final exp = _prefs.getInt('acct_exp') ?? 0;
    if (access != null && DateTime.now().millisecondsSinceEpoch < exp) return access;
    final r = await http.post(_u('/.netlify/identity/token'),
        body: {'grant_type': 'refresh_token', 'refresh_token': refresh}).timeout(
        const Duration(seconds: 15));
    if (r.statusCode >= 300) {
      if (r.statusCode == 400 || r.statusCode == 401) await logout();
      return null;
    }
    await _storeTokens(jsonDecode(r.body) as Map<String, dynamic>, email ?? '');
    return _prefs.getString('acct_access');
  }

  // ---------------------------------------------------------------- Spielstand

  /// Spielstand vom Server (oder null, wenn es noch keinen gibt).
  Future<({int updatedAt, Map<String, dynamic> data})?> _fetch() async {
    final t = await _token();
    if (t == null) throw StateError('Nicht angemeldet');
    final r = await http.get(_u('/api/save'), headers: {'authorization': 'Bearer $t'}).timeout(
        const Duration(seconds: 20));
    if (r.statusCode != 200) throw StateError('Server: ${r.statusCode}');
    final j = jsonDecode(r.body);
    if (j is! Map<String, dynamic>) return null;
    return (updatedAt: (j['updatedAt'] as num).toInt(), data: j['data'] as Map<String, dynamic>);
  }

  Future<bool> upload() async {
    if (!loggedIn || busy) return false;
    busy = true;
    try {
      final t = await _token();
      if (t == null) return false;
      final now = DateTime.now().millisecondsSinceEpoch;
      final r = await http
          .put(_u('/api/save'),
              headers: {'content-type': 'application/json', 'authorization': 'Bearer $t'},
              body: jsonEncode({'updatedAt': now, 'data': _progress.exportSnapshot()}))
          .timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) {
        lastError = 'Hochladen fehlgeschlagen (${r.statusCode}).';
        return false;
      }
      await _prefs.setInt('acct_last_sync', now);
      lastError = null;
      return true;
    } catch (_) {
      lastError = 'Keine Verbindung – wird später nachgeholt.';
      return false;
    } finally {
      busy = false;
      changed.value++;
    }
  }

  Future<bool> download() async {
    try {
      final save = await _fetch();
      if (save == null) return false;
      await _progress.importSnapshot(save.data);
      await _prefs.setInt('acct_last_sync', save.updatedAt);
      lastError = null;
      onRestored?.call();
      return true;
    } catch (_) {
      lastError = 'Laden fehlgeschlagen.';
      return false;
    } finally {
      changed.value++;
    }
  }

  /// Gibt es online einen Spielstand? (für die Frage nach dem Anmelden)
  Future<bool?> hasRemote() async {
    try {
      return await _fetch() != null;
    } catch (_) {
      return null;
    }
  }

  /// Beim Start: Ist der Online-Stand neuer (auf anderem Gerät gespielt)?
  /// Dann laden, sonst den hiesigen Stand hochladen.
  Future<void> syncOnStart() async {
    if (!loggedIn) return;
    try {
      final save = await _fetch();
      final last = _prefs.getInt('acct_last_sync') ?? 0;
      if (save != null && save.updatedAt > last) {
        await download();
      } else {
        await upload();
      }
    } catch (_) {
      lastError = 'Offline – Sync folgt später.';
      changed.value++;
    }
  }

  Timer? _debounce;

  /// Nach Änderungen (Lauf beendet, Kauf …) kurz warten und hochladen.
  void scheduleUpload() {
    if (!loggedIn) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 3), upload);
  }
}
