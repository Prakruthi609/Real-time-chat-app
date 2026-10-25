import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

const apiUrl = String.fromEnvironment('API_URL', defaultValue: 'http://10.0.2.2:8000');

void main() => runApp(const ProviderScope(child: ChatApp()));

class Msg {
  final int id;
  final String sender, text;
  Msg(this.id, this.sender, this.text);
  factory Msg.fromJson(Map<String, dynamic> j) => Msg(j['id'], j['sender'], j['text']);
}

final tokenProvider = StateProvider<String?>((_) => null);
final userProvider = StateProvider<String>((_) => '');

final historyProvider = FutureProvider.autoDispose<List<Msg>>((ref) async {
  final token = ref.watch(tokenProvider);
  final r = await http
      .get(Uri.parse('$apiUrl/messages'), headers: {'Authorization': 'Bearer $token'})
      .timeout(const Duration(seconds: 10));
  if (r.statusCode != 200) throw Exception('Server error (${r.statusCode})');
  return (jsonDecode(r.body) as List).map((e) => Msg.fromJson(e)).toList();
});

Future<String> authenticate(String u, String p, {required bool register}) async {
  if (register) {
    final r = await http.post(Uri.parse('$apiUrl/register'),
        headers: {'Content-Type': 'application/json'}, body: jsonEncode({'username': u, 'password': p}));
    if (r.statusCode != 201) {
      throw Exception(r.statusCode == 409 ? 'Username already taken' : 'Username 3-32 letters/numbers, password 6+ chars');
    }
  }
  final r = await http.post(Uri.parse('$apiUrl/login'), body: {'username': u, 'password': p});
  if (r.statusCode != 200) throw Exception('Invalid username or password');
  return jsonDecode(r.body)['access_token'];
}

class ChatApp extends ConsumerWidget {
  const ChatApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final token = ref.watch(tokenProvider);
    return MaterialApp(
      title: 'Realtime Chat',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: token == null ? const LoginPage() : const ChatPage(),
    );
  }
}

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});
  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _user = TextEditingController(), _pass = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _submit(bool register) async {
    if (_user.text.trim().isEmpty || _pass.text.isEmpty) {
      setState(() => _error = 'Enter username and password');
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      final t = await authenticate(_user.text.trim(), _pass.text, register: register);
      ref.read(userProvider.notifier).state = _user.text.trim();
      ref.read(tokenProvider.notifier).state = t;
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text('Welcome', style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 16),
                TextField(controller: _user, decoration: const InputDecoration(labelText: 'Username')),
                TextField(controller: _pass, obscureText: true, decoration: const InputDecoration(labelText: 'Password')),
                if (_error != null)
                  Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Colors.red))),
                const SizedBox(height: 16),
                if (_busy) const CircularProgressIndicator() else ...[
                  FilledButton(onPressed: () => _submit(false), child: const Text('Sign in')),
                  OutlinedButton(onPressed: () => _submit(true), child: const Text('Create account')),
                ],
              ]),
            ),
          ),
        ),
      );
}

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key});
  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  WebSocketChannel? _ch;
  final _live = <Msg>[];
  final _input = TextEditingController();
  List<String> _online = [];
  bool _connected = false;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  void _connect() {
    final token = ref.read(tokenProvider);
    final ws = apiUrl.replaceFirst('http', 'ws');
    _ch = WebSocketChannel.connect(Uri.parse('$ws/ws?token=$token'));
    setState(() => _connected = true);
    _ch!.stream.listen((raw) {
      if (!mounted) return;
      final j = jsonDecode(raw);
      setState(() {
        if (j['type'] == 'message') {
          _live.add(Msg.fromJson(j));
        } else {
          _online = List<String>.from(j['users']);
        }
      });
    }, onError: (_) => _lost(), onDone: _lost);
  }

  void _lost() {
    if (mounted) setState(() => _connected = false);
  }

  void _send() {
    final t = _input.text.trim();
    if (t.isEmpty || !_connected) return;
    _ch!.sink.add(t);
    _input.clear();
  }

  @override
  void dispose() {
    _ch?.sink.close();
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(historyProvider);
    final me = ref.watch(userProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text('Chat · ${_online.length} online'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => ref.read(tokenProvider.notifier).state = null,
          ),
        ],
      ),
      body: Column(children: [
        if (!_connected)
          MaterialBanner(
            content: const Text('Disconnected'),
            actions: [TextButton(onPressed: _connect, child: const Text('Reconnect'))],
          ),
        Expanded(
          child: history.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('Could not load messages'),
                TextButton(onPressed: () => ref.invalidate(historyProvider), child: const Text('Retry')),
              ]),
            ),
            data: (old) {
              final seen = <int>{};
              final all = [...old, ..._live].where((m) => seen.add(m.id)).toList();
              if (all.isEmpty) return const Center(child: Text('No messages yet. Say hi!'));
              return ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: all.length,
                itemBuilder: (_, i) {
                  final m = all[i];
                  final mine = m.sender == me;
                  return Align(
                    alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                    child: Card(
                      color: mine ? Theme.of(context).colorScheme.primaryContainer : null,
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          if (!mine) Text(m.sender, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                          Text(m.text),
                        ]),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(children: [
              Expanded(child: TextField(controller: _input, onSubmitted: (_) => _send(), decoration: const InputDecoration(hintText: 'Message'))),
              IconButton(icon: const Icon(Icons.send), onPressed: _send),
            ]),
          ),
        ),
      ]),
    );
  }
}