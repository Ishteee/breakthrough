import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:web_socket_channel/status.dart' as ws_status;
import 'package:web_socket_channel/web_socket_channel.dart';

const _serverUrl = 'ws://172.25.24.108:8080/ws';
const _sendInterval = Duration(seconds: 5);
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
}

class _TrackedUser {
  _TrackedUser({
    required this.userID,
    required this.from,
    required this.to,
    required this.updatedAt,
    required this.color,
    required this.isSelf,
  });

  final String userID;
  LatLng from;
  LatLng to;
  DateTime updatedAt;
  final Color color;
  final bool isSelf;
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
  final _userIDController = TextEditingController(
    text: 'user-${math.Random().nextInt(9000) + 1000}',
  );
  final _mapController = MapController();
  final Map<String, _TrackedUser> _users = {};

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _sendTimer;
  late final Ticker _ticker;
  String? _myUserID;
  bool _connected = false;
  bool _connecting = false;
  bool _hasFramed = false;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _cleanupConnection();
    _userIDController.dispose();
    super.dispose();
  }

  void _onTick(Duration _) {
    if (_users.isEmpty) return;
    final now = DateTime.now();
    final animating = _users.values.any(
      (u) => now.difference(u.updatedAt) < _sendInterval,
    );
    if (!animating) return;
    setState(() => _now = now);
  }

  LatLng _interpolate(_TrackedUser u) {
    final elapsed = _now.difference(u.updatedAt).inMilliseconds;
    final total = _sendInterval.inMilliseconds;
    final t = (elapsed / total).clamp(0.0, 1.0);
    final eased = Curves.easeInOut.transform(t);
    return LatLng(
      lerpDouble(u.from.latitude, u.to.latitude, eased)!,
      lerpDouble(u.from.longitude, u.to.longitude, eased)!,
    );
  }

  Color _colorForUserID(String userID) {
    var hash = 0;
    for (final ch in userID.codeUnits) {
      hash = (hash * 31 + ch) & 0x7fffffff;
    }
    final hue = (hash % 360).toDouble();
    return HSLColor.fromAHSL(1.0, hue, 0.65, 0.52).toColor();
  }

  Future<void> _connect() async {
    final userID = _userIDController.text.trim();
    if (userID.isEmpty) {
      _snack('Enter a name first');
      return;
    }

    setState(() => _connecting = true);

    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(() => _connecting = false);
      _snack('Turn on location services');
      return;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      setState(() => _connecting = false);
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
      setState(() {
        _connected = true;
        _connecting = false;
      });
      _startSending();
    } catch (_) {
      setState(() => _connecting = false);
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
      channel.sink.add(jsonEncode({
        'userID': userID,
        'lat': pos.latitude,
        'lng': pos.longitude,
      }));
    } catch (_) {}
  }

  void _onMessage(dynamic data) {
    try {
      final json = jsonDecode(data as String) as Map<String, dynamic>;
      final msg = LocationMessage.fromJson(json);
      final newPos = LatLng(msg.lat, msg.lng);
      final now = DateTime.now();
      final existing = _users[msg.userID];
      if (existing != null) {
        final currentPos = _interpolate(existing);
        existing
          ..from = currentPos
          ..to = newPos
          ..updatedAt = now;
      } else {
        _users[msg.userID] = _TrackedUser(
          userID: msg.userID,
          from: newPos,
          to: newPos,
          updatedAt: now,
          color: _colorForUserID(msg.userID),
          isSelf: msg.userID == _myUserID,
        );
      }
      setState(() => _now = now);

      if (!_hasFramed && msg.userID == _myUserID) {
        _hasFramed = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _mapController.move(newPos, 16);
        });
      }
    } catch (_) {}
  }

  void _onDisconnected(String reason) {
    if (!_connected) return;
    _cleanupConnection();
    if (mounted) {
      setState(() {
        _connected = false;
        _users.clear();
        _hasFramed = false;
      });
      _snack(reason);
    }
  }

  void _disconnect() {
    _cleanupConnection();
    if (mounted) {
      setState(() {
        _connected = false;
        _users.clear();
        _hasFramed = false;
      });
    }
  }

  void _cleanupConnection() {
    _sendTimer?.cancel();
    _sendTimer = null;
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close(ws_status.normalClosure);
    _channel = null;
    _myUserID = null;
  }

  void _fitAll() {
    if (_users.isEmpty) return;
    final points = _users.values.map(_interpolate).toList();
    if (points.length == 1) {
      _mapController.move(points.first, 16);
      return;
    }
    _mapController.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(points),
        padding: const EdgeInsets.fromLTRB(60, 200, 60, 140),
      ),
    );
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final users = _users.values.toList();

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          _MapLayer(
            mapController: _mapController,
            users: users,
            interpolator: _interpolate,
          ),
          if (!_connected)
            IgnorePointer(
              child: Container(color: cs.surface.withValues(alpha: 0.15)),
            ),
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: _TopPanel(
                    connected: _connected,
                    connecting: _connecting,
                    userIDController: _userIDController,
                    myUserID: _myUserID,
                    userCount: _users.length,
                    onConnect: _connect,
                    onDisconnect: _disconnect,
                  ),
                ),
              ),
            ),
          ),
          if (_connected)
            SafeArea(
              child: Align(
                alignment: Alignment.bottomRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 16, bottom: 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (users.isNotEmpty)
                        _RoundIconButton(
                          icon: Icons.center_focus_strong_rounded,
                          tooltip: 'Fit all',
                          onPressed: _fitAll,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          if (_connected && users.isEmpty)
            const IgnorePointer(
              child: Align(
                alignment: Alignment.center,
                child: _WaitingPill(),
              ),
            ),
        ],
      ),
    );
  }
}

class _MapLayer extends StatelessWidget {
  const _MapLayer({
    required this.mapController,
    required this.users,
    required this.interpolator,
  });

  final MapController mapController;
  final List<_TrackedUser> users;
  final LatLng Function(_TrackedUser) interpolator;

  @override
  Widget build(BuildContext context) {
    return FlutterMap(
      mapController: mapController,
      options: MapOptions(
        initialCenter: const LatLng(20, 0),
        initialZoom: 2,
        minZoom: 2,
        maxZoom: 19,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
        ),
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.example.breakthrough',
          maxZoom: 19,
          retinaMode: RetinaMode.isHighDensity(context),
        ),
        MarkerLayer(
          markers: [
            for (final u in users)
              Marker(
                point: interpolator(u),
                width: 56,
                height: 56,
                alignment: Alignment.center,
                child: _UserMarker(
                  userID: u.userID,
                  color: u.color,
                  isSelf: u.isSelf,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _UserMarker extends StatefulWidget {
  const _UserMarker({
    required this.userID,
    required this.color,
    required this.isSelf,
  });

  final String userID;
  final Color color;
  final bool isSelf;

  @override
  State<_UserMarker> createState() => _UserMarkerState();
}

class _UserMarkerState extends State<_UserMarker>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final initial = widget.userID.isEmpty
        ? '?'
        : widget.userID.substring(0, 1).toUpperCase();
    return Tooltip(
      message: widget.userID,
      preferBelow: false,
      child: SizedBox(
        width: 56,
        height: 56,
        child: Stack(
          alignment: Alignment.center,
          children: [
            AnimatedBuilder(
              animation: _pulse,
              builder: (_, _) {
                final t = _pulse.value;
                final size = 24 + t * 28;
                return Container(
                  width: size,
                  height: size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.color
                        .withValues(alpha: (1 - t) * (widget.isSelf ? 0.45 : 0.25)),
                  ),
                );
              },
            ),
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    widget.color,
                    HSLColor.fromColor(widget.color)
                        .withLightness(
                          (HSLColor.fromColor(widget.color).lightness - 0.12)
                              .clamp(0.0, 1.0),
                        )
                        .toColor(),
                  ],
                ),
                border: Border.all(color: Colors.white, width: 2.5),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              alignment: Alignment.center,
              child: Text(
                initial,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopPanel extends StatelessWidget {
  const _TopPanel({
    required this.connected,
    required this.connecting,
    required this.userIDController,
    required this.myUserID,
    required this.userCount,
    required this.onConnect,
    required this.onDisconnect,
  });

  final bool connected;
  final bool connecting;
  final TextEditingController userIDController;
  final String? myUserID;
  final int userCount;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          decoration: BoxDecoration(
            color: cs.surface.withValues(alpha: 0.82),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: cs.outlineVariant.withValues(alpha: 0.5),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  _LogoMark(),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Breakthrough',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.2,
                              ),
                        ),
                        const SizedBox(height: 2),
                        _StatusChip(
                          connected: connected,
                          myUserID: myUserID,
                          count: userCount,
                        ),
                      ],
                    ),
                  ),
                  if (connected)
                    IconButton.filledTonal(
                      onPressed: onDisconnect,
                      tooltip: 'Disconnect',
                      icon: const Icon(Icons.logout_rounded),
                    ),
                ],
              ),
              if (!connected) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: userIDController,
                        enabled: !connecting,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => onConnect(),
                        decoration: InputDecoration(
                          hintText: 'Your name',
                          prefixIcon:
                              const Icon(Icons.person_rounded, size: 20),
                          filled: true,
                          fillColor: cs.surfaceContainerHighest,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 14,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: connecting ? null : onConnect,
                      icon: connecting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.bolt_rounded),
                      label: Text(connecting ? 'Connecting' : 'Connect'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 14,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _LogoMark extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [cs.primary, cs.tertiary],
        ),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: cs.primary.withValues(alpha: 0.3),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: const Icon(
        Icons.travel_explore_rounded,
        color: Colors.white,
        size: 22,
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.connected,
    required this.myUserID,
    required this.count,
  });

  final bool connected;
  final String? myUserID;
  final int count;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dot = connected ? const Color(0xFF22C55E) : cs.outline;
    final label = connected
        ? '$count on the map · you are $myUserID'
        : 'Not connected';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _LivePulse(color: dot, active: connected),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}

class _LivePulse extends StatefulWidget {
  const _LivePulse({required this.color, required this.active});

  final Color color;
  final bool active;

  @override
  State<_LivePulse> createState() => _LivePulseState();
}

class _LivePulseState extends State<_LivePulse>
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
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: widget.color,
        ),
      );
    }
    return SizedBox(
      width: 16,
      height: 16,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, _) {
          final t = _ctrl.value;
          return Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 8 + t * 8,
                height: 8 + t * 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color.withValues(alpha: (1 - t) * 0.5),
                ),
              ),
              Container(
                width: 8,
                height: 8,
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

class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Material(
        elevation: 4,
        shadowColor: Colors.black.withValues(alpha: 0.2),
        color: cs.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: cs.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onPressed,
          child: SizedBox(
            width: 52,
            height: 52,
            child: Icon(icon, color: cs.primary),
          ),
        ),
      ),
    );
  }
}

class _WaitingPill extends StatelessWidget {
  const _WaitingPill();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(
            color: cs.surface.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: cs.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: cs.primary,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                'Waiting for the first ping',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}