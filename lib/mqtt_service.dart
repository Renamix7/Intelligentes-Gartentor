// ignore_for_file: prefer_const_constructors

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;
import 'package:shared_preferences/shared_preferences.dart';

// MQTT (Flutter Web via WebSocket)
import 'package:mqtt_client/mqtt_browser_client.dart';
import 'package:mqtt_client/mqtt_client.dart';

// ========================= HELPERS =========================

String _formatDateTimeShort(DateTime dt) {
  final local = dt.toLocal();
  return "${local.day.toString().padLeft(2, '0')}"
      ".${local.month.toString().padLeft(2, '0')}"
      ".${local.year} "
      "${local.hour.toString().padLeft(2, '0')}:"
      "${local.minute.toString().padLeft(2, '0')}";
}

String _normalizePlate(String input) {
  return input.toUpperCase().replaceAll(RegExp(r'[\s\-\._]'), '').trim();
}

/// Allow normal plates + "Wunschkennzeichen":
/// Examples allowed:
/// - VIECH1, LAP187, MD123AB
/// Rules:
/// - length 3..10
/// - only letters/digits
/// - must contain at least one digit + at least one letter
bool _looksLikePlate(String input) {
  final s = _normalizePlate(input);

  if (s.length < 3 || s.length > 10) return false;
  if (!RegExp(r'^[A-Z0-9]+$').hasMatch(s)) return false;

  final hasDigit = RegExp(r'\d').hasMatch(s);
  final hasLetter = RegExp(r'[A-Z]').hasMatch(s);
  if (!hasDigit || !hasLetter) return false;

  final letters = RegExp(r'[A-Z]').allMatches(s).length;
  final digits = RegExp(r'\d').allMatches(s).length;

  if (digits > 6) return false;
  if (s.length >= 9 && (digits <= 1 || letters <= 1)) return false;

  return true;
}

// ========================= MQTT SERVICE (INLINE) =========================

class MqttService {
  final String wsUrl; // e.g. "ws://100.95.51.36:1884"
  final String username;
  final String password;

  late final MqttBrowserClient client;

  MqttService({
    required this.wsUrl,
    required this.username,
    required this.password,
  }) {
    client = MqttBrowserClient(
      wsUrl,
      'flutter_web_${DateTime.now().millisecondsSinceEpoch}',
    );
    client.keepAlivePeriod = 20;
    client.logging(on: false);
  }

  Future<void> connect() async {
    client.connectionMessage = MqttConnectMessage()
        .withClientIdentifier(client.clientIdentifier)
        .authenticateAs(username, password)
        .startClean()
        .withWillQos(MqttQos.atMostOnce);

    try {
      await client.connect();
    } catch (e) {
      client.disconnect();
      rethrow;
    }

    if (client.connectionStatus?.state != MqttConnectionState.connected) {
      throw Exception('MQTT not connected: ${client.connectionStatus}');
    }
  }

  void subscribe(String topic) {
    client.subscribe(topic, MqttQos.atMostOnce);
  }

  Stream<Map<String, dynamic>> messages() {
    final updates = client.updates;
    if (updates == null) return const Stream.empty();

    return updates.expand((events) => events).map((event) {
      final rec = event.payload as MqttPublishMessage;
      final payload = MqttPublishPayload.bytesToStringAsString(
        rec.payload.message,
      );

      Map<String, dynamic>? json;
      try {
        final decoded = jsonDecode(payload);
        if (decoded is Map<String, dynamic>) json = decoded;
      } catch (_) {}

      return {
        'topic': event.topic,
        'payload': payload,
        'json': json,
      };
    });
  }

  void publishJson(String topic, Map<String, dynamic> data) {
    final builder = MqttClientPayloadBuilder();
    builder.addString(jsonEncode(data));
    client.publishMessage(topic, MqttQos.atMostOnce, builder.payload!);
  }

  void disconnect() => client.disconnect();
}

// ========================= MAIN =========================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await sb.Supabase.initialize(
    url: 'https://ioktgcicufdxckxfgona.supabase.co',
    anonKey:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imlva3RnY2ljdWZkeGNreGZnb25hIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjMwMjg2NjUsImV4cCI6MjA3ODYwNDY2NX0.ElsqdyCYztYha9xQ672ZhQhHIRhGsiw4wWObJreKl2A',
  );

  runApp(const GateApp());
}

// ========================= THEME CONTROLLER =========================

class ThemeController extends ChangeNotifier {
  static const _prefKey = 'isDarkTheme';
  bool _isDark = true;
  bool _initialized = false;

  bool get isDark => _isDark;
  bool get initialized => _initialized;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _isDark = prefs.getBool(_prefKey) ?? true;
    _initialized = true;
    notifyListeners();
  }

  Future<void> toggle() async {
    _isDark = !_isDark;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKey, _isDark);
  }
}

// ========================= MODELS =========================

class AppUser {
  final String username;
  final bool isAdmin;
  const AppUser(this.username, {this.isAdmin = false});
}

class Plate {
  String number;
  bool permanent;
  DateTime? validUntil;
  Plate({required this.number, this.permanent = true, this.validUntil});

  bool get isTemporarilyValid =>
      !permanent && validUntil != null && DateTime.now().isBefore(validUntil!);

  bool get isExpiredTemporary =>
      !permanent && validUntil != null && DateTime.now().isAfter(validUntil!);
}

class AccessEvent {
  final DateTime time;
  final String plate;
  final String action;
  final String by;
  AccessEvent({
    required this.time,
    required this.plate,
    required this.action,
    required this.by,
  });
}

class AccessRequest {
  final String id;
  final DateTime time;
  final String plate;
  AccessRequest({required this.id, required this.time, required this.plate});
}

// ========================= APP STATE =========================

class AppState extends ChangeNotifier {
  final sb.SupabaseClient supabase = sb.Supabase.instance.client;

  AppUser? currentUser;

  final List<Plate> plates = [];
  final List<AccessEvent> events = [];

  // DB Requests (optional/polling) + MQTT Requests (live)
  final List<AccessRequest> requests = [];

  final StreamController<AccessRequest> _requestStream =
      StreamController.broadcast();

  Stream<AccessRequest> get requestStream => _requestStream.stream;

  Timer? _refreshTimer;

  // ================= MQTT CONFIG =================
  // Flutter Web needs WebSocket. Mosquitto add-on shows WS on 1884.
  static const String mqttWsUrl = 'ws://100.95.51.36:1884';
  static const String mqttUser = 'homeassistant';
  static const String mqttPass = '__123456789';

  static const String topicRequests = 'gartentor/requests';
  static const String topicCmd = 'gartentor/cmd';

  MqttService? _mqtt;
  StreamSubscription? _mqttSub;

  Future<void> startMqtt() async {
    if (_mqtt != null) return;

    final svc = MqttService(
      wsUrl: mqttWsUrl,
      username: mqttUser,
      password: mqttPass,
    );

    await svc.connect();

    // Subscribe to HA -> Website requests
    svc.subscribe(topicRequests);

    _mqttSub = svc.messages().listen((msg) {
      // DEBUG: if you want, uncomment:
      // print('MQTT MSG: $msg');

      if (msg['topic'] != topicRequests) return;

      final j = msg['json'];
      if (j == null) return;

      final cmd = (j['cmd'] ?? '').toString().toUpperCase();
      if (cmd != 'REQUEST') return;

      final plate = (j['plate'] ?? '').toString();
      if (plate.isEmpty) return;

      final req = AccessRequest(
        id: 'mqtt_${DateTime.now().millisecondsSinceEpoch}',
        time: DateTime.now(),
        plate: plate,
      );

      // keep newest on top
      requests.insert(0, req);
      _requestStream.add(req);
      notifyListeners();
    });

    _mqtt = svc;
  }

  void stopMqtt() {
    _mqttSub?.cancel();
    _mqttSub = null;
    _mqtt?.disconnect();
    _mqtt = null;
  }

  void startAutoRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      // NOTE: we intentionally do NOT call loadRequests() here,
      // because it would overwrite/erase MQTT-live requests.
      await Future.wait([
        loadPlates(),
        loadEvents(),
      ]);
    });
  }

  void stopAutoRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  Future<bool> login(String username, String password) async {
    await Future.delayed(const Duration(milliseconds: 250));
    final ok = (username == 'admin' && password == 'admin');
    if (ok) {
      currentUser = const AppUser('admin', isAdmin: true);
      await loadAll();
      startAutoRefresh();
      notifyListeners();
    }
    return ok;
  }

  void logout() {
    stopAutoRefresh();
    currentUser = null;
    notifyListeners();
  }

  Future<void> loadAll() async {
    await Future.wait([
      loadPlates(),
      loadEvents(),
      // If you still want DB requests in addition to MQTT requests,
      // call loadRequests() manually from a button later.
    ]);
  }

  Future<void> loadPlates() async {
    final data =
        await supabase.from('plates').select().order('id', ascending: false);

    final now = DateTime.now();
    final expiredNumbers = <String>[];

    final loaded = data.map<Plate>((row) {
      final vu = row['valid_until'];
      DateTime? validUntil;
      if (vu != null) validUntil = DateTime.parse(vu.toString());

      final p = Plate(
        number: row['number'] as String,
        permanent: row['permanent'] as bool,
        validUntil: validUntil,
      );

      if (!p.permanent && p.validUntil != null && now.isAfter(p.validUntil!)) {
        expiredNumbers.add(p.number);
      }
      return p;
    }).toList();

    if (expiredNumbers.isNotEmpty) {
      final filter = expiredNumbers.map((n) => 'number.eq.$n').join(',');
      await supabase.from('plates').delete().or(filter);
    }

    plates
      ..clear()
      ..addAll(
        loaded.where((p) =>
            p.permanent ||
            (p.validUntil != null && now.isBefore(p.validUntil!))),
      );

    notifyListeners();
  }

  Future<void> loadEvents() async {
    final data = await supabase
        .from('access_events')
        .select()
        .order('time', ascending: false);

    events
      ..clear()
      ..addAll(data.map<AccessEvent>((row) {
        final t = row['time'];
        return AccessEvent(
          time: DateTime.parse(t.toString()),
          plate: row['plate'] as String,
          action: row['action'] as String,
          by: row['by_user'] as String,
        );
      }));

    notifyListeners();
  }

  // Optional: keep your DB requests if you still need them
  Future<void> loadRequests() async {
    final data = await supabase
        .from('access_requests')
        .select()
        .order('request_time', ascending: false);

    final loaded = data.map<AccessRequest>((row) {
      final rt = row['request_time'];
      return AccessRequest(
        id: row['id'].toString(),
        time: DateTime.parse(rt.toString()),
        plate: row['plate'] as String,
      );
    }).toList();

    // merge DB requests into list without deleting MQTT ones
    final mqttOnes = requests.where((r) => r.id.startsWith('mqtt_')).toList();
    requests
      ..clear()
      ..addAll(mqttOnes)
      ..addAll(loaded);

    notifyListeners();
  }

  Future<void> addPlate(Plate plate, {String by = 'system'}) async {
    await supabase.from('plates').insert({
      'number': _normalizePlate(plate.number),
      'permanent': plate.permanent,
      'valid_until': plate.validUntil?.toUtc().toIso8601String(),
    });

    await supabase.from('access_events').insert({
      'plate': _normalizePlate(plate.number),
      'action': 'plate_added',
      'by_user': by,
    });

    await loadPlates();
    await loadEvents();
  }

  Future<void> updatePlate(Plate updated, {String by = 'system'}) async {
    await supabase
        .from('plates')
        .update({
          'permanent': updated.permanent,
          'valid_until': updated.validUntil?.toUtc().toIso8601String(),
        })
        .eq('number', _normalizePlate(updated.number));

    await supabase.from('access_events').insert({
      'plate': _normalizePlate(updated.number),
      'action': 'plate_updated',
      'by_user': by,
    });

    await loadPlates();
    await loadEvents();
  }

  Future<void> removePlate(String number, {String by = 'system'}) async {
    final n = _normalizePlate(number);

    await supabase.from('plates').delete().eq('number', n);

    await supabase.from('access_events').insert({
      'plate': n,
      'action': 'plate_removed',
      'by_user': by,
    });

    await loadPlates();
    await loadEvents();
  }

  // Create a request from a plate (DB flow)
  Future<void> enqueueRequest(String plate, {String by = 'robin'}) async {
    final normalized = _normalizePlate(plate);

    await loadPlates();

    final match =
        plates.where((p) => _normalizePlate(p.number) == normalized).toList();
    final isKnown = match.isNotEmpty;
    final isAllowed =
        isKnown && (match.first.permanent || match.first.isTemporarilyValid);

    await supabase.from('access_events').insert({
      'plate': normalized,
      'action': isAllowed ? 'seen_allowed' : 'seen_unknown',
      'by_user': by,
    });

    if (!isAllowed) {
      final data = await supabase
          .from('access_requests')
          .insert({'plate': normalized})
          .select()
          .single();

      await supabase.from('access_events').insert({
        'plate': normalized,
        'action': 'request_created',
        'by_user': by,
      });

      final rt = data['request_time'];
      final req = AccessRequest(
        id: data['id'].toString(),
        time: DateTime.parse(rt.toString()),
        plate: data['plate'] as String,
      );

      requests.insert(0, req);
      _requestStream.add(req);
    }

    await loadEvents();
    await loadRequests();
    notifyListeners();
  }

  Future<void> approveRequest(AccessRequest req, {required String by}) async {
    // MQTT open command
    _mqtt?.publishJson(topicCmd, {
      'cmd': 'OPEN',
      'plate': req.plate,
      'by': by,
      'ts': DateTime.now().toIso8601String(),
    });

    await supabase.from('access_events').insert({
      'plate': req.plate,
      'action': 'opened',
      'by_user': by,
    });

    if (!req.id.startsWith('mqtt_')) {
      final idInt = int.tryParse(req.id);
      await supabase.from('access_requests').delete().eq('id', idInt ?? req.id);
    }

    requests.removeWhere((r) => r.id == req.id);
    await loadEvents();
    notifyListeners();
  }

  Future<void> denyRequest(AccessRequest req, {required String by}) async {
    _mqtt?.publishJson(topicCmd, {
      'cmd': 'CLOSE',
      'plate': req.plate,
      'by': by,
      'ts': DateTime.now().toIso8601String(),
    });

    await supabase.from('access_events').insert({
      'plate': req.plate,
      'action': 'denied',
      'by_user': by,
    });

    if (!req.id.startsWith('mqtt_')) {
      final idInt = int.tryParse(req.id);
      await supabase.from('access_requests').delete().eq('id', idInt ?? req.id);
    }

    requests.removeWhere((r) => r.id == req.id);
    await loadEvents();
    notifyListeners();
  }

  Future<void> sendGateCommand(String command, {required String by}) async {
    _mqtt?.publishJson(topicCmd, {
      'cmd': command.toLowerCase() == 'open' ? 'OPEN' : 'CLOSE',
      'plate': 'ADMIN',
      'by': by,
      'ts': DateTime.now().toIso8601String(),
    });

    await supabase.from('gate_commands').insert({
      'command': command,
      'by_user': by,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });

    await supabase.from('access_events').insert({
      'plate': 'ADMIN',
      'action': 'gate_$command',
      'by_user': by,
    });

    await loadEvents();
    notifyListeners();
  }

  @override
  void dispose() {
    stopAutoRefresh();
    stopMqtt();
    _requestStream.close();
    super.dispose();
  }
}

// ========================= ROOT WIDGET =========================

class GateApp extends StatefulWidget {
  const GateApp({super.key});

  @override
  State<GateApp> createState() => _GateAppState();
}

class _GateAppState extends State<GateApp> {
  final AppState state = AppState();
  final ThemeController theme = ThemeController();

  @override
  void initState() {
    super.initState();
    theme.load();

    // START MQTT IMMEDIATELY (even before login)
    Future.microtask(() async {
      try {
        await state.startMqtt();
      } catch (_) {
        // ignore; app still works (Supabase features still work)
      }
    });
  }

  @override
  void dispose() {
    state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: theme,
      builder: (context, _) {
        if (!theme.initialized) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            home: const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            ),
          );
        }

        final isDark = theme.isDark;

        return MaterialApp(
          title: 'Intelligentes Gartentor',
          debugShowCheckedModeBanner: false,
          theme: isDark ? _buildDarkTheme() : _buildLightTheme(),
          home: Scaffold(
            backgroundColor: Colors.transparent,
            body: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: isDark
                      ? const [
                          Color(0xFF05060A),
                          Color(0xFF080A14),
                          Color(0xFF05060A),
                        ]
                      : const [
                          Color(0xFFF3F6FF),
                          Color(0xFFE9ECF7),
                          Color(0xFFF3F6FF),
                        ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: AnimatedBuilder(
                      animation: state,
                      builder: (context, _) {
                        return state.currentUser == null
                            ? LoginScreen(state: state, theme: theme)
                            : Dashboard(state: state, theme: theme);
                      },
                    ),
                  ),
                  Positioned(
                    bottom: 18,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      child: Center(
                        child: Opacity(
                          opacity: isDark ? 0.20 : 0.15,
                          child: Text(
                            "© Intelligentes Gartentor Diplomarbeit",
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 18,
                              letterSpacing: 1.1,
                              fontWeight: FontWeight.w600,
                              color: isDark
                                  ? const Color(0xFF2979FF)
                                  : const Color(0xFF1857D8),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// ========================= THEME DEFINITIONS =========================

ThemeData _buildDarkTheme() {
  const baseColor = Color(0xFF2979FF);

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: ColorScheme.fromSeed(
      seedColor: baseColor,
      brightness: Brightness.dark,
    ),
    scaffoldBackgroundColor: const Color(0xFF05060A),
    cardColor: const Color(0xFF14151C),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFF090A10),
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: Colors.white,
      ),
    ),
    dividerColor: const Color(0xFF25263A),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: Color(0xFF1E1F2A),
      contentTextStyle: TextStyle(color: Colors.white),
    ),
  );
}

ThemeData _buildLightTheme() {
  const primary = Color(0xFF2979FF);

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: ColorScheme.fromSeed(
      seedColor: primary,
      brightness: Brightness.light,
    ),
    scaffoldBackgroundColor: const Color(0xFFF5F7FC),
    cardColor: Colors.white,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.white,
      elevation: 1,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: Colors.black87,
      ),
      iconTheme: IconThemeData(color: Colors.black87),
    ),
    dividerColor: const Color(0xFFDFE3F0),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: Colors.black87,
      contentTextStyle: TextStyle(color: Colors.white),
    ),
  );
}

// ========================= LOGIN SCREEN =========================

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.state, required this.theme});
  final AppState state;
  final ThemeController theme;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final isDark = widget.theme.isDark;
    final cardGradient = isDark
        ? const LinearGradient(
            colors: [Color(0xFF151623), Color(0xFF10111A)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          )
        : const LinearGradient(
            colors: [Colors.white, Color(0xFFF5F7FF)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          );

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Card(
            elevation: 10,
            shadowColor: Colors.black.withOpacity(isDark ? 0.8 : 0.2),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                gradient: cardGradient,
                border: Border.all(
                  color: isDark
                      ? const Color(0xFF2A2C3F)
                      : const Color(0xFFD5DAF0),
                  width: 1,
                ),
              ),
              padding: const EdgeInsets.all(24.0),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Align(
                      alignment: Alignment.topRight,
                      child: IconButton(
                        tooltip:
                            widget.theme.isDark ? 'Light Mode' : 'Dark Mode',
                        onPressed: widget.theme.toggle,
                        icon: Icon(
                          widget.theme.isDark
                              ? Icons.light_mode
                              : Icons.dark_mode,
                        ),
                      ),
                    ),
                    const Icon(Icons.garage_outlined,
                        size: 40, color: Color(0xFF2979FF)),
                    const SizedBox(height: 12),
                    const Text(
                      'Admin Login',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Intelligentes Gartentor — Dashboard',
                      style: TextStyle(
                        fontSize: 13,
                        color: isDark
                            ? Colors.white.withOpacity(0.7)
                            : Colors.black.withOpacity(0.6),
                      ),
                    ),
                    const SizedBox(height: 24),
                    TextFormField(
                      controller: _userCtrl,
                      decoration: const InputDecoration(labelText: 'Username'),
                      validator: (v) =>
                          (v == null || v.isEmpty) ? 'Required' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _passCtrl,
                      decoration: const InputDecoration(labelText: 'Password'),
                      obscureText: true,
                      validator: (v) =>
                          (v == null || v.isEmpty) ? 'Required' : null,
                    ),
                    const SizedBox(height: 16),
                    if (_error != null)
                      Text(
                        _error!,
                        style: const TextStyle(color: Colors.redAccent),
                      ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _loading
                            ? null
                            : () async {
                                if (!_formKey.currentState!.validate()) return;
                                setState(() {
                                  _loading = true;
                                  _error = null;
                                });
                                final ok = await widget.state.login(
                                  _userCtrl.text.trim(),
                                  _passCtrl.text,
                                );
                                setState(() => _loading = false);
                                if (!ok) {
                                  setState(() =>
                                      _error = 'Login failed (admin/admin)');
                                }
                              },
                        child: _loading
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('Sign in'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ========================= DASHBOARD =========================

class Dashboard extends StatefulWidget {
  const Dashboard({super.key, required this.state, required this.theme});
  final AppState state;
  final ThemeController theme;

  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 4, vsync: this);
  StreamSubscription<AccessRequest>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.state.requestStream.listen((req) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Access request: ${req.plate}')),
      );
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final admin = widget.state.currentUser!;
    final scheme = Theme.of(context).colorScheme;
    final isDark = widget.theme.isDark;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Admin — Intelligentes Gartentor'),
        actions: [
          IconButton(
            tooltip: widget.theme.isDark ? 'Light Mode' : 'Dark Mode',
            onPressed: widget.theme.toggle,
            icon: Icon(
              widget.theme.isDark ? Icons.light_mode : Icons.dark_mode,
            ),
          ),
          IconButton(
            tooltip: 'Logout',
            onPressed: widget.state.logout,
            icon: const Icon(Icons.logout),
          )
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Column(
            children: [
              TabBar(
                controller: _tabs,
                labelStyle: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 13),
                unselectedLabelColor: isDark ? Colors.white70 : Colors.black54,
                labelColor: scheme.primary,
                indicatorColor: scheme.primary,
                indicatorWeight: 3,
                tabs: const [
                  Tab(text: 'Anfragen'),
                  Tab(text: 'Kennzeichen'),
                  Tab(text: 'Protokoll'),
                  Tab(text: 'Admin'),
                ],
              ),
              Container(
                height: 1,
                color: (isDark ? Colors.white : Colors.black).withOpacity(0.08),
              )
            ],
          ),
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          RequestsTab(state: widget.state),
          PlatesTab(state: widget.state),
          LogTab(state: widget.state),
          AdminTab(admin: admin, state: widget.state),
        ],
      ),
    );
  }
}

// ========================= TAB: REQUESTS =========================

class RequestsTab extends StatelessWidget {
  const RequestsTab({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;

    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        if (state.requests.isEmpty) {
          return Center(
            child: Text(
              'No pending requests.',
              style: TextStyle(
                color: isDark ? Colors.white70 : Colors.black54,
              ),
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: state.requests.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final req = state.requests[i];
            return Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(
                  color: isDark
                      ? const Color(0xFF26283A)
                      : const Color(0xFFDFE3F0),
                ),
              ),
              child: ListTile(
                title: Text(
                  'Plate: ${req.plate}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  'Time: ${_formatDateTimeShort(req.time)}',
                  style: TextStyle(
                    color: isDark ? Colors.white70 : Colors.black54,
                    fontSize: 12,
                  ),
                ),
                trailing: Wrap(
                  spacing: 8,
                  children: [
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.greenAccent.shade400,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                      ),
                      onPressed: () async => await state.approveRequest(
                        req,
                        by: state.currentUser!.username,
                      ),
                      icon: const Icon(Icons.lock_open),
                      label: const Text('Open'),
                    ),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.redAccent,
                        side: const BorderSide(color: Colors.redAccent),
                      ),
                      onPressed: () async => await state.denyRequest(
                        req,
                        by: state.currentUser!.username,
                      ),
                      icon: const Icon(Icons.close),
                      label: const Text('Deny'),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// ========================= TAB: PLATES =========================

class PlatesTab extends StatefulWidget {
  const PlatesTab({super.key, required this.state});
  final AppState state;

  @override
  State<PlatesTab> createState() => _PlatesTabState();
}

class _PlatesTabState extends State<PlatesTab> {
  final _plateCtrl = TextEditingController();
  bool _temporary = false;
  DateTime? _until;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;

    return Row(
      children: [
        Expanded(
          flex: 2,
          child: AnimatedBuilder(
            animation: widget.state,
            builder: (_, __) {
              if (widget.state.plates.isEmpty) {
                return Center(
                  child: Text(
                    'No plates configured yet.',
                    style: TextStyle(
                      color: isDark ? Colors.white70 : Colors.black54,
                    ),
                  ),
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: widget.state.plates.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, i) {
                  final p = widget.state.plates[i];
                  final subtitle = p.permanent
                      ? 'Permanent'
                      : 'Temporary until: ${p.validUntil == null ? '-' : _formatDateTimeShort(p.validUntil!)}';

                  return Card(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(
                        color: isDark
                            ? const Color(0xFF26283A)
                            : const Color(0xFFDFE3F0),
                      ),
                    ),
                    child: ListTile(
                      title: Text(
                        p.number,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 15),
                      ),
                      subtitle: Text(
                        subtitle,
                        style: TextStyle(
                          color: isDark ? Colors.white70 : Colors.black54,
                          fontSize: 12,
                        ),
                      ),
                      trailing: IconButton(
                        tooltip: 'Delete',
                        onPressed: () async => await widget.state.removePlate(
                          p.number,
                          by: widget.state.currentUser!.username,
                        ),
                        icon: const Icon(Icons.delete_outline),
                        color: Colors.redAccent,
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Add plate',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _plateCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Plate number',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Temporary access'),
                  value: _temporary,
                  onChanged: (v) => setState(() => _temporary = v),
                ),
                if (_temporary) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final now = DateTime.now();
                      final picked = await showDatePicker(
                        context: context,
                        firstDate: now,
                        lastDate: now.add(const Duration(days: 365)),
                        initialDate: now,
                      );
                      if (picked == null) return;
                      final time = await showTimePicker(
                        context: context,
                        initialTime: TimeOfDay.now(),
                      );
                      if (time == null) return;
                      setState(() {
                        _until = DateTime(picked.year, picked.month, picked.day,
                            time.hour, time.minute);
                      });
                    },
                    icon: const Icon(Icons.schedule),
                    label: Text(_until == null
                        ? 'Choose expiry'
                        : 'Until: ${_formatDateTimeShort(_until!)}'),
                  ),
                ],
                const Spacer(),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () async {
                      final raw = _plateCtrl.text.trim();
                      if (raw.isEmpty) return;

                      if (!_looksLikePlate(raw)) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                                'Kennzeichen wirkt unrealistisch. Beispiele: VIECH1 / LAP187 / W123AB'),
                          ),
                        );
                        return;
                      }

                      final plateNum = _normalizePlate(raw);

                      final plate = Plate(
                        number: plateNum,
                        permanent: !_temporary,
                        validUntil: _temporary ? _until : null,
                      );
                      await widget.state.addPlate(
                        plate,
                        by: widget.state.currentUser!.username,
                      );
                      _plateCtrl.clear();
                      setState(() {
                        _temporary = false;
                        _until = null;
                      });
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('Add'),
                  ),
                )
              ],
            ),
          ),
        )
      ],
    );
  }
}

// ========================= TAB: LOG =========================

class LogTab extends StatelessWidget {
  const LogTab({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;

    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        if (state.events.isEmpty) {
          return Center(
            child: Text(
              'No events yet.',
              style: TextStyle(
                color: isDark ? Colors.white70 : Colors.black54,
              ),
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: state.events.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final e = state.events[i];
            return Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(
                  color: isDark
                      ? const Color(0xFF26283A)
                      : const Color(0xFFDFE3F0),
                ),
              ),
              child: ListTile(
                leading: Icon(_iconForAction(e.action),
                    color: _colorForAction(e.action)),
                title: Text('${e.action} — ${e.plate}',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(
                  'Time: ${_formatDateTimeShort(e.time)} | by: ${e.by}',
                  style: TextStyle(
                    color: isDark ? Colors.white70 : Colors.black54,
                    fontSize: 12,
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  IconData _iconForAction(String a) {
    switch (a) {
      case 'opened':
        return Icons.lock_open;
      case 'denied':
        return Icons.close;
      case 'plate_added':
        return Icons.add;
      case 'plate_updated':
        return Icons.edit;
      case 'plate_removed':
        return Icons.delete;
      case 'gate_open':
        return Icons.door_front_door_outlined;
      case 'gate_close':
        return Icons.door_front_door;
      case 'seen_allowed':
        return Icons.verified_rounded;
      case 'seen_unknown':
        return Icons.help_outline_rounded;
      case 'request_created':
        return Icons.notification_important_rounded;
      default:
        return Icons.event_note;
    }
  }

  Color _colorForAction(String a) {
    switch (a) {
      case 'opened':
        return Colors.greenAccent;
      case 'denied':
        return Colors.redAccent;
      case 'plate_added':
        return Colors.lightBlueAccent;
      case 'plate_updated':
        return Colors.amberAccent;
      case 'plate_removed':
        return Colors.pinkAccent;
      case 'gate_open':
        return Colors.lightGreenAccent;
      case 'gate_close':
        return Colors.orangeAccent;
      case 'seen_allowed':
        return Colors.lightGreenAccent;
      case 'seen_unknown':
        return Colors.orangeAccent;
      case 'request_created':
        return Colors.amberAccent;
      default:
        return Colors.white;
    }
  }
}

// ========================= TAB: ADMIN =========================

class AdminTab extends StatelessWidget {
  const AdminTab({super.key, required this.admin, required this.state});
  final AppUser admin;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;

    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        final recent = state.events
            .where((e) =>
                e.by.toLowerCase() == 'robin' &&
                (e.action == 'seen_allowed' ||
                    e.action == 'seen_unknown' ||
                    e.action == 'request_created'))
            .take(8)
            .toList();

        return ListView(
          padding: const EdgeInsets.all(18),
          children: [
            Text('Admin Panel',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(
              'Signed in as: ${admin.username}',
              style: TextStyle(
                color: isDark ? Colors.white70 : Colors.black54,
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _MiniAction(
                  label: 'Open',
                  icon: Icons.lock_open_rounded,
                  color: Colors.lightGreenAccent,
                  onTap: () async {
                    await state.sendGateCommand('open', by: admin.username);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Gate command sent: OPEN')),
                    );
                  },
                ),
                _MiniAction(
                  label: 'Close',
                  icon: Icons.lock_rounded,
                  color: Colors.redAccent,
                  onTap: () async {
                    await state.sendGateCommand('close', by: admin.username);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Gate command sent: CLOSE')),
                    );
                  },
                ),
                _MiniAction(
                  label: 'Logout',
                  icon: Icons.logout,
                  color: scheme.primary,
                  onTap: state.logout,
                ),
              ],
            ),
            const SizedBox(height: 18),
            Text(
              'Letzte Kennzeichen',
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
            const SizedBox(height: 10),
            Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(
                  color: isDark
                      ? const Color(0xFF26283A)
                      : const Color(0xFFDFE3F0),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: recent.isEmpty
                    ? Text(
                        'Noch keine Kennzeichen empfangen.',
                        style: TextStyle(
                          color: isDark ? Colors.white70 : Colors.black54,
                        ),
                      )
                    : Column(
                        children: recent.map((e) {
                          final status = _statusText(e.action);
                          final badge = _statusBadge(e.action);
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Row(
                              children: [
                                Container(
                                  width: 10,
                                  height: 10,
                                  decoration: BoxDecoration(
                                    color: badge,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        e.plate,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 14,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '${_formatDateTimeShort(e.time)} • $status',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: isDark
                                              ? Colors.white70
                                              : Colors.black54,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 10),
                                _Pill(text: status, color: badge),
                              ],
                            ),
                          );
                        }).toList(),
                      ),
              ),
            ),
          ],
        );
      },
    );
  }

  static String _statusText(String action) {
    switch (action) {
      case 'seen_allowed':
        return 'Erlaubt';
      case 'seen_unknown':
        return 'Unbekannt';
      case 'request_created':
        return 'Request';
      default:
        return action;
    }
  }

  static Color _statusBadge(String action) {
    switch (action) {
      case 'seen_allowed':
        return Colors.lightGreenAccent;
      case 'seen_unknown':
        return Colors.orangeAccent;
      case 'request_created':
        return Colors.amberAccent;
      default:
        return Colors.blueGrey;
    }
  }
}

// ========================= UI HELPERS =========================

class _Pill extends StatelessWidget {
  const _Pill({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.18),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Text(
        text,
        style: TextStyle(
            fontSize: 11, fontWeight: FontWeight.w700, color: color),
      ),
    );
  }
}

class _MiniAction extends StatelessWidget {
  const _MiniAction({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          color: isDark ? Colors.white.withOpacity(0.05) : Colors.white,
          border: Border.all(color: color.withOpacity(0.35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 7),
            Text(
              label,
              style: TextStyle(fontWeight: FontWeight.w700, color: color),
            ),
          ],
        ),
      ),
    );
  }
}
