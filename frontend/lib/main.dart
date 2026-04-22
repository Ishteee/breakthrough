import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const _serverUrl = 'ws://172.25.24.108:8080/ws';
const _sendInterval = Duration(seconds: 5);
const _maxContentWidth = 640.0;
const _seedColor = Color(0xFF6366F1);

void main() {
  runApp(const BreakthroughApp());
}

class BreakthroughApp extends StatelessWidget {
  const BreakthroughApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Breakthrough',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: _seedColor),
        scaffoldBackgroundColor: const Color(0xFFF6F6FB),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _seedColor,
          brightness: Brightness.dark,
        ),
      ),
      home: const HomePage(),
    );
  }
}

class LocationMessage {
  final String userID;
  final double lat;
  final double lng;
  final int timestamp;

  LocationMessage({
    required this.userID,
    required this.lat,
    required this.lng,
    required this.timestamp,
  });

  factory LocationMessage.fromJson(Map<String, dynamic> json) {
    return LocationMessage(
      userID: json['userID'] as String,
      lat: (json['lat'] as num).toDouble(),
      lng: (json['lng'] as num).toDouble(),
      timestamp: json['timestamp'] as int,
    );
  }

  DateTime get time => DateTime.fromMillisecondsSinceEpoch(timestamp);
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _userIDController = TextEditingController();
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _sendTimer;
  Timer? _uiTicker;
  String? _myUserID;
  bool _connected = false;
  final List<LocationMessage> _messages = [];

  @override
  void initState() {
    super.initState();
    _uiTicker = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _uiTicker?.cancel();
    _disconnect();
    _userIDController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final userID = _userIDController.text.trim();
    if (userID.isEmpty) {
      _snack('Enter a name first');
      return;
    }

    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      _snack('Turn on location services');
      return;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      _snack('Location permission denied');
      return;
    }

    try {
      final channel = WebSocketChannel.connect(Uri.parse(_serverUrl));
      await channel.ready;
      _channel = channel;
      _myUserID = userID;
      _subscription = channel.stream.listen(
        _onMessage,
        onError: (_) => _onDisconnected('Connection error'),
        onDone: () => _onDisconnected('Disconnected'),
      );
      setState(() => _connected = true);
      _startSending();
    } catch (_) {
      _snack('Failed to connect');
    }
  }

  void _startSending() {
    _sendTimer?.cancel();
    _sendTimer = Timer.periodic(_sendInterval, (_) => _sendLocation());
    _sendLocation();
  }

  Future<void> _sendLocation() async {
    final channel = _channel;
    final userID = _myUserID;
    if (channel == null || userID == null) return;
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
      final payload = jsonEncode({
        'userID': userID,
        'lat': pos.latitude,
        'lng': pos.longitude,
      });
      channel.sink.add(payload);
    } catch (_) {}
  }

  void _onMessage(dynamic data) {
    try {
      final json = jsonDecode(data as String) as Map<String, dynamic>;
      final msg = LocationMessage.fromJson(json);
      setState(() {
        _messages.insert(0, msg);
        if (_messages.length > 100) _messages.removeLast();
      });
    } catch (_) {}
  }

  void _onDisconnected(String reason) {
    _disconnect();
    _snack(reason);
  }

  void _disconnect() {
    _sendTimer?.cancel();
    _sendTimer = null;
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
    _myUserID = null;
    if (mounted) setState(() => _connected = false);
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _maxContentWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _Header(),
                _StatusCard(
                  connected: _connected,
                  userID: _myUserID,
                  messageCount: _messages.length,
                ),
                _ControlsCard(
                  connected: _connected,
                  controller: _userIDController,
                  onConnect: _connect,
                  onDisconnect: _disconnect,
                ),
                const SizedBox(height: 4),
                Expanded(child: _messageList()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _messageList() {
    if (_messages.isEmpty) {
      return _EmptyState(connected: _connected);
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: _messages.length,
      itemBuilder: (ctx, i) {
        final m = _messages[i];
        return _LocationCard(message: m, isMe: m.userID == _myUserID);
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  theme.colorScheme.primary,
                  theme.colorScheme.tertiary,
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: theme.colorScheme.primary.withValues(alpha: 0.25),
                  blurRadius: 14,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: const Icon(Icons.explore_rounded,
                color: Colors.white, size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Breakthrough',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                  ),
                ),
                Text(
                  'Share your location with friends',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final bool connected;
  final String? userID;
  final int messageCount;

  const _StatusCard({
    required this.connected,
    required this.userID,
    required this.messageCount,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = connected
        ? const Color(0xFF16A34A)
        : theme.colorScheme.error;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          _PulseDot(color: color, active: connected),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              connected ? 'Connected as $userID' : 'Not connected',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (connected)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '$messageCount',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ControlsCard extends StatelessWidget {
  final bool connected;
  final TextEditingController controller;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;

  const _ControlsCard({
    required this.connected,
    required this.controller,
    required this.onConnect,
    required this.onDisconnect,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: connected
          ? SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: onDisconnect,
                icon: const Icon(Icons.logout_rounded),
                label: const Text('Disconnect'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            )
          : Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => onConnect(),
                    decoration: InputDecoration(
                      hintText: 'Your name',
                      prefixIcon:
                          const Icon(Icons.person_rounded, size: 20),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                      fillColor: theme.colorScheme.surfaceContainerHighest,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 14),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: onConnect,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 22, vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text(
                    'Connect',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
    );
  }
}

class _PulseDot extends StatefulWidget {
  final Color color;
  final bool active;
  const _PulseDot({required this.color, required this.active});

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) {
      return Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: widget.color,
        ),
      );
    }
    return SizedBox(
      width: 22,
      height: 22,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, _) {
          final t = _ctrl.value;
          return Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 22 * (0.45 + 0.55 * t),
                height: 22 * (0.45 + 0.55 * t),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color.withValues(alpha: (1 - t) * 0.45),
                ),
              ),
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final bool connected;
  const _EmptyState({required this.connected});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(
                connected
                    ? Icons.location_searching_rounded
                    : Icons.wifi_tethering_off_rounded,
                size: 38,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              connected
                  ? 'Waiting for the first ping'
                  : 'You are not connected',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              connected
                  ? 'Your location will appear here as soon as it is sent.'
                  : 'Enter your name and tap Connect to start sharing.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LocationCard extends StatelessWidget {
  final LocationMessage message;
  final bool isMe;
  const _LocationCard({required this.message, required this.isMe});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final initial = message.userID.isEmpty
        ? '?'
        : message.userID.substring(0, 1).toUpperCase();
    final accent =
        isMe ? theme.colorScheme.primary : theme.colorScheme.tertiary;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isMe
              ? theme.colorScheme.primary.withValues(alpha: 0.35)
              : theme.colorScheme.outlineVariant,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [accent, accent.withValues(alpha: 0.7)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(14),
            ),
            alignment: Alignment.center,
            child: Text(
              initial,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 18,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        message.userID,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isMe) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'you',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onPrimaryContainer,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${message.lat.toStringAsFixed(5)}, ${message.lng.toStringAsFixed(5)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _relativeTime(message.time),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

String _relativeTime(DateTime t) {
  final diff = DateTime.now().difference(t);
  if (diff.inSeconds < 5) return 'just now';
  if (diff.inMinutes < 1) return '${diff.inSeconds}s ago';
  if (diff.inHours < 1) return '${diff.inMinutes}m ago';
  return '${diff.inHours}h ago';
}