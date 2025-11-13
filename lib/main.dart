import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

// BAVRKA - Intelligentes Gartentor - main
// flutter run -d chrome

String _formatTime(DateTime dt) {
  final local = dt.toLocal();
  return "${local.day.toString().padLeft(2, '0')}"
         ".${local.month.toString().padLeft(2, '0')}"
         ".${local.year} "
         "${local.hour.toString().padLeft(2, '0')}:"
         "${local.minute.toString().padLeft(2, '0')}:"
         "${local.second.toString().padLeft(2, '0')}";
}
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await sb.Supabase.initialize(
    url: 'https://ioktgcicufdxckxfgona.supabase.co',       
    anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imlva3RnY2ljdWZkeGNreGZnb25hIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjMwMjg2NjUsImV4cCI6MjA3ODYwNDY2NX0.ElsqdyCYztYha9xQ672ZhQhHIRhGsiw4wWObJreKl2A',
  );

  runApp(const GateApp());
}

// ========================= MODELS =========================

// User + role
class AppUser {
  final String username;
  final bool isAdmin;
  const AppUser(this.username, {this.isAdmin = false});
}

// License plate (permanent/temporary)
class Plate {
  String number;
  bool permanent;
  DateTime? validUntil; // for temporary access
  Plate({required this.number, this.permanent = true, this.validUntil});

  // Logic: check temporary validity
  bool get isTemporarilyValid =>
      !permanent && validUntil != null && DateTime.now().isBefore(validUntil!);
}

// Audit log event
class AccessEvent {
  final DateTime time;
  final String plate;
  final String action; // opened/denied/added/removed
  final String by;
  AccessEvent(
      {required this.time,
      required this.plate,
      required this.action,
      required this.by});
}

// Model: incoming access request
class AccessRequest {
  final String id;
  final DateTime time;
  final String plate;
  AccessRequest({required this.id, required this.time, required this.plate});
}

// ========================= APP STATE =========================

// App-wide state + business logic (Single Source of Truth)
class AppState extends ChangeNotifier {
  final sb.SupabaseClient supabase = sb.Supabase.instance.client;

  // Currently logged-in user
  AppUser? currentUser;

  // Central data lists (lokaler Cache)
  final List<Plate> plates = [];
  final List<AccessEvent> events = [];
  final List<AccessRequest> requests = [];

  // "Realtime" stream for incoming requests (UI SnackBar)
  final StreamController<AccessRequest> _requestStream =
      StreamController.broadcast();
  Stream<AccessRequest> get requestStream => _requestStream.stream;

  // AUTH  (einfacher Demo-Login)
  Future<bool> login(String username, String password) async {
    await Future.delayed(const Duration(milliseconds: 300));
    final ok = (username == 'admin' && password == 'admin');
    if (ok) {
      currentUser = const AppUser('admin', isAdmin: true);
      await loadAll(); // nach Login alle Daten laden
      notifyListeners();
    }
    return ok;
  }

  // Logout: clear user + update UI
  void logout() {
    currentUser = null;
    notifyListeners();
  }

  // --------- Ladefunktionen ---------

  Future<void> loadAll() async {
    await Future.wait([
      loadPlates(),
      loadEvents(),
      loadRequests(),
    ]);
  }

  Future<void> loadPlates() async {
    final data = await supabase
        .from('plates')
        .select()
        .order('id', ascending: false);

    plates
      ..clear()
      ..addAll(data.map<Plate>((row) {
        final vu = row['valid_until'];
        DateTime? validUntil;
        if (vu != null) {
          validUntil = DateTime.parse(vu.toString());
        }
        return Plate(
          number: row['number'] as String,
          permanent: row['permanent'] as bool,
          validUntil: validUntil,
        );
      }));

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

  Future<void> loadRequests() async {
    final data = await supabase
        .from('access_requests')
        .select()
        .order('request_time', ascending: false);

    requests
      ..clear()
      ..addAll(data.map<AccessRequest>((row) {
        final rt = row['request_time'];
        return AccessRequest(
          id: row['id'].toString(),
          time: DateTime.parse(rt.toString()),
          plate: row['plate'] as String,
        );
      }));

    notifyListeners();
  }

  // --------- Plates API (Supabase + Cache) ---------

  Future<void> addPlate(Plate plate, {String by = 'system'}) async {
    await supabase.from('plates').insert({
      'number': plate.number,
      'permanent': plate.permanent,
      'valid_until': plate.validUntil?.toIso8601String(),
    });

    await supabase.from('access_events').insert({
      'plate': plate.number,
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
          'valid_until': updated.validUntil?.toIso8601String(),
        })
        .eq('number', updated.number);

    await supabase.from('access_events').insert({
      'plate': updated.number,
      'action': 'plate_updated',
      'by_user': by,
    });

    await loadPlates();
    await loadEvents();
  }

  Future<void> removePlate(String number, {String by = 'system'}) async {
    await supabase.from('plates').delete().eq('number', number);

    await supabase.from('access_events').insert({
      'plate': number,
      'action': 'plate_removed',
      'by_user': by,
    });

    await loadPlates();
    await loadEvents();
  }

  // --------- Requests API ---------

  Future<void> enqueueRequest(String plate) async {
    final data = await supabase
        .from('access_requests')
        .insert({'plate': plate})
        .select()
        .single();

    final rt = data['request_time'];
    final req = AccessRequest(
      id: data['id'].toString(),
      time: DateTime.parse(rt.toString()),
      plate: data['plate'] as String,
    );

    requests.insert(0, req);
    _requestStream.add(req); // Broadcast to dashboard (SnackBar)
    notifyListeners();
  }

  Future<void> approveRequest(AccessRequest req, {required String by}) async {
    await supabase.from('access_events').insert({
      'plate': req.plate,
      'action': 'opened',
      'by_user': by,
    });

    final idInt = int.tryParse(req.id);
    await supabase
        .from('access_requests')
        .delete()
        .eq('id', idInt ?? req.id);

    await loadEvents();
    await loadRequests();
  }

  Future<void> denyRequest(AccessRequest req, {required String by}) async {
    await supabase.from('access_events').insert({
      'plate': req.plate,
      'action': 'denied',
      'by_user': by,
    });

    final idInt = int.tryParse(req.id);
    await supabase
        .from('access_requests')
        .delete()
        .eq('id', idInt ?? req.id);

    await loadEvents();
    await loadRequests();
  }

  @override
  void dispose() {
    _requestStream.close();
    super.dispose();
  }
}

// ========================= ROOT WIDGET =========================

// Root widget: MaterialApp + routing (Login ↔ Dashboard)
class GateApp extends StatefulWidget {
  const GateApp({super.key});

  @override
  State<GateApp> createState() => _GateAppState();
}

class _GateAppState extends State<GateApp> {
  final AppState state = AppState();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Intelligentes Gartentor',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.red),
      // AnimatedBuilder listens to notifyListeners()
      home: AnimatedBuilder(
        animation: state,
        builder: (context, _) {
          return state.currentUser == null
              ? LoginScreen(state: state) // not logged in → Login
              : Dashboard(state: state); // logged in → Dashboard
        },
      ),
    );
  }
}

// ========================= LOGIN SCREEN =========================

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.state});
  final AppState state;

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
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Login',
                        style: TextStyle(
                            fontSize: 24, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 16),
                    // Input: username
                    TextFormField(
                      controller: _userCtrl,
                      decoration:
                          const InputDecoration(labelText: 'Username'),
                      validator: (v) =>
                          (v == null || v.isEmpty) ? 'Required' : null,
                    ),
                    const SizedBox(height: 12),
                    // Input: password
                    TextFormField(
                      controller: _passCtrl,
                      decoration:
                          const InputDecoration(labelText: 'Password'),
                      obscureText: true,
                      validator: (v) =>
                          (v == null || v.isEmpty) ? 'Required' : null,
                    ),
                    const SizedBox(height: 16),
                    if (_error != null)
                      Text(_error!,
                          style: const TextStyle(color: Colors.red)),
                    const SizedBox(height: 8),
                    // Action: login
                    FilledButton(
                      onPressed: _loading
                          ? null
                          : () async {
                              if (!_formKey.currentState!.validate()) return;
                              setState(() => _loading = true);
                              final ok = await widget.state.login(
                                  _userCtrl.text.trim(), _passCtrl.text);
                              setState(() => _loading = false);
                              if (!ok) {
                                setState(() => _error = 'Login failed');
                              }
                            },
                      child: _loading
                          ? const CircularProgressIndicator()
                          : const Text('Sign in'),
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

// DASHBOARD (Tabs + SnackBar + FAB)
class Dashboard extends StatefulWidget {
  const Dashboard({super.key, required this.state});
  final AppState state;

  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard>
    with SingleTickerProviderStateMixin {
  // 4 Tabs
  late final TabController _tabs = TabController(length: 4, vsync: this);
  // Subscription to "realtime" requests
  StreamSubscription<AccessRequest>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.state.requestStream.listen((req) {
      if (!mounted) return;
      // Simulated notification
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin — Intelligentes Gartentor'),
        actions: [
          IconButton(
            tooltip: 'Logout',
            onPressed: widget.state.logout,
            icon: const Icon(Icons.logout),
          )
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Anfragen'),
            Tab(text: 'Kennzeichen'),
            Tab(text: 'Protokoll'),
            Tab(text: 'Admin'),
          ],
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
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final demoPlate = (widget.state.plates.isNotEmpty)
              ? widget.state.plates.first.number
              : 'UNKNOWN';
          await widget.state.enqueueRequest(demoPlate);
        },
        label: const Text('Simulate request'),
        icon: const Icon(Icons.live_tv),
      ),
    );
  }
}

// ========================= TAB: REQUESTS =========================

// TAB: Requests (approve / deny)
class RequestsTab extends StatelessWidget {
  const RequestsTab({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        if (state.requests.isEmpty) {
          return const Center(child: Text('No pending requests.'));
        }
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: state.requests.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final req = state.requests[i];
            return Card(
              child: ListTile(
                title: Text('Plate: ${req.plate}'),
                subtitle: Text('Time: ${req.time.toLocal()}'),
                trailing: Wrap(spacing: 8, children: [
                  // Approve → open gate
                  ElevatedButton.icon(
                    onPressed: () async => await state.approveRequest(
                        req,
                        by: state.currentUser!.username),
                    icon: const Icon(Icons.lock_open),
                    label: const Text('Open'),
                  ),
                  // Deny
                  OutlinedButton.icon(
                    onPressed: () async => await state.denyRequest(
                        req,
                        by: state.currentUser!.username),
                    icon: const Icon(Icons.close),
                    label: const Text('Deny'),
                  ),
                ]),
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
  // UI state: inputs
  final _plateCtrl = TextEditingController();
  bool _temporary = false;
  DateTime? _until;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        // Left column: list
        Expanded(
          flex: 2,
          child: AnimatedBuilder(
            animation: widget.state,
            builder: (_, __) {
              return ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: widget.state.plates.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, i) {
                  final p = widget.state.plates[i];
                  final subtitle = p.permanent
                      ? 'Permanent'
                      : 'Temporary until: ${p.validUntil?.toLocal() ?? '-'}';
                  return Card(
                    child: ListTile(
                      title: Text(p.number),
                      subtitle: Text(subtitle),
                      trailing: Wrap(spacing: 8, children: [
                        // Delete a plate
                        IconButton(
                          tooltip: 'Delete',
                          onPressed: () async => await widget.state.removePlate(
                              p.number,
                              by: widget.state.currentUser!.username),
                          icon: const Icon(Icons.delete),
                        ),
                      ]),
                    ),
                  );
                },
              );
            },
          ),
        ),
        const VerticalDivider(width: 1),
        // Right column: form + temporary access
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Add plate',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                TextField(
                  controller: _plateCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Plate number',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                // Toggle: temporary access
                SwitchListTile(
                  title: const Text('Temporary access'),
                  value: _temporary,
                  onChanged: (v) => setState(() => _temporary = v),
                ),
                if (_temporary) ...[
                  const SizedBox(height: 8),
                  // Pick date/time
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
                          context: context, initialTime: TimeOfDay.now());
                      if (time == null) return;
                      setState(() => _until = DateTime(picked.year, picked.month,
                          picked.day, time.hour, time.minute));
                    },
                    icon: const Icon(Icons.schedule),
                    label: Text(_until == null
                        ? 'Choose expiry'
                        : 'Until: ${_until!.toLocal()}'),
                  ),
                ],
                const Spacer(),
                // Add button: create Plate + call
                FilledButton.icon(
                  onPressed: () async {
                    final plateNum = _plateCtrl.text.trim();
                    if (plateNum.isEmpty) return;
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

// TAB: Log (audit/activity)
class LogTab extends StatelessWidget {
  const LogTab({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        if (state.events.isEmpty) {
          return const Center(child: Text('No events yet.'));
        }
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: state.events.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final e = state.events[i];
            return Card(
              child: ListTile(
                leading: Icon(_iconForAction(e.action)),
                title: Text('${e.action} — ${e.plate}'),
                subtitle: Text(
                    'Time: ${_formatTime(e.time)} | by: ${e.by}'),
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
      default:
        return Icons.event_note;
    }
  }
}

// ========================= TAB: ADMIN =========================

// Admin tab (always visible)
class AdminTab extends StatelessWidget {
  const AdminTab({super.key, required this.admin, required this.state});
  final AppUser admin;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('Admin Panel',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        Text('Signed in as: ${admin.username}'),
        const SizedBox(height: 12),
        const Divider(),
        const Text('Quick actions'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: () async {
                if (state.plates.isNotEmpty) {
                  await state.enqueueRequest(state.plates.first.number);
                } else {
                  await state.enqueueRequest('UNKNOWN');
                }
              },
              icon: const Icon(Icons.bolt),
              label: const Text('Simulate access request'),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                final demo =
                    'DEMO-${DateTime.now().millisecondsSinceEpoch % 10000}';
                await state.addPlate(Plate(number: demo),
                    by: admin.username);
              },
              icon: const Icon(Icons.playlist_add),
              label: const Text('Add demo plate'),
            ),
            OutlinedButton.icon(
              onPressed: () => state.logout(),
              icon: const Icon(Icons.logout),
              label: const Text('Logout'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        const Divider(),
        const Text('Notes'),
        const SizedBox(height: 8),
        const Text(
          'This is an admin-only UI. All data is now stored in Supabase '
          '(plates, access requests, events). Replace the simple demo login '
          'with real Supabase Auth if needed.',
        ),
      ],
    );
  }
}
