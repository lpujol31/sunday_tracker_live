import 'dart:async';
import 'dart:math' as math;
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html show document;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:intl/intl.dart';
import 'package:google_fonts/google_fonts.dart';

const List<Map<String, dynamic>> kMapStyles = [
  {
    'label': 'Plan',
    'icon': Icons.map,
    'url': 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    'subdomains': <String>[],
    'maxZoom': 19,
  },
  {
    'label': 'Satellite',
    'icon': Icons.satellite_alt,
    'url':
        'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
    'subdomains': <String>[],
    'maxZoom': 19,
  },
  {
    'label': 'Topo',
    'icon': Icons.terrain,
    'url': 'https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png',
    'subdomains': <String>['a', 'b', 'c'],
    'maxZoom': 17,
  },
];

List<Color> _buildGradientColors(int count) {
  const colors = [
    Color(0xFFFF8A00),
    Color(0xFFD946EF),
    Color(0xFF6D28D9),
  ];
  if (count <= 1) return [colors.first];
  return List.generate(count, (i) {
    final t = i / (count - 1);
    if (t <= 0.5) {
      return Color.lerp(colors[0], colors[1], t / 0.5)!;
    } else {
      return Color.lerp(colors[1], colors[2], (t - 0.5) / 0.5)!;
    }
  });
}

class LivePage extends StatefulWidget {
  const LivePage({super.key});

  @override
  State<LivePage> createState() => _LivePageState();
}

class _LivePageState extends State<LivePage> {
  bool isLoading = true;
  bool isRefreshing = false;
  String? errorMessage;
  String? errorDetails;
  bool _errorDetailsExpanded = false;

  double? latitude;
  double? longitude;
  DateTime? lastUpdate;

  String appVersion = '';
  String rideStatus = 'unknown';
  String? _previousRideStatus;

  List<Map<String, dynamic>> tracePositions = [];

  double _totalDistanceMeters = 0;
  Duration _rideDuration = Duration.zero;
  DateTime? rideStartTime;

  Timer? _tickerTimer;
  Duration _sinceLastUpdate = Duration.zero;

  MapController mapController = MapController();
  int _mapStyleIndex = 0;
  bool _mapFitDone = false;
  bool _mapReady = false;

  double _savedZoom = 15.0;
  LatLng? _savedCenter;

  Timer? refreshTimer;
  int refreshIntervalSeconds = 30;

  final shareCode = Uri.base.queryParameters['code'];

  List<Map<String, dynamic>> _checkpoints = [];
  bool _waypointsPanelOpen = false;

  @override
  void initState() {
    super.initState();
    loadAppVersion();
    loadLastPosition();
    startAutoRefresh();
    _tickerTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (lastUpdate != null) setState(() { _sinceLastUpdate = DateTime.now().difference(lastUpdate!); });
    });
  }

  @override
  void dispose() {
    refreshTimer?.cancel();
    _tickerTimer?.cancel();
    super.dispose();
  }

  String _formatSinceLastUpdate() {
    if (_isFinished && lastUpdate != null) {
      final dt = lastUpdate!.toLocal();
      return 'Arrivée à ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    if (rideStatus == 'unknown' || lastUpdate == null) return 'Position inconnue';
    final s = _sinceLastUpdate.inSeconds;
    if (s < 60) return 'il y a $s s';
    final m = _sinceLastUpdate.inMinutes;
    if (m < 60) return 'il y a $m min';
    final h = _sinceLastUpdate.inHours;
    return 'il y a ${h}h${(m - h * 60).toString().padLeft(2, '0')}';
  }

  Widget _buildStatusPill() {
    final color = getStatusColor();
    final icon = getStatusIcon();
    final label = _isFinished ? 'Ride terminé'
        : rideStatus == 'in_progress' ? 'En cours'
        : rideStatus == 'paused' ? 'En pause'
        : 'Statut du ride indisponible';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 11),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  bool get _isFinished => rideStatus == 'finished';

  void startAutoRefresh() {
    refreshTimer?.cancel();
    // Pas de polling si le ride est terminé ou si l'intervalle est désactivé
    if (refreshIntervalSeconds == 0 || _isFinished) return;
    refreshTimer = Timer.periodic(
      Duration(seconds: refreshIntervalSeconds),
      (_) => loadLastPosition(),
    );
  }

  void changeRefreshInterval(int seconds) {
    setState(() => refreshIntervalSeconds = seconds);
    startAutoRefresh();
  }

  void _stopPollingIfFinished() {
    if (_isFinished) {
      refreshTimer?.cancel();
      refreshTimer = null;
      _tickerTimer?.cancel();
      _tickerTimer = null;
    }
  }

  Future<void> loadAppVersion() async {
    final packageInfo = await PackageInfo.fromPlatform();
    final formattedDate = packageInfo.updateTime != null
        ? DateFormat('dd/MM/yyyy HH:mm').format(packageInfo.updateTime!)
        : null;
    setState(() {
      appVersion =
          'v${packageInfo.version}+${packageInfo.buildNumber}'
          '${formattedDate != null ? ' - $formattedDate' : ''}';
    });
  }

  IconData getStatusIcon() {
    switch (rideStatus) {
      case 'in_progress': return Icons.play_circle;
      case 'paused': return Icons.pause_circle;
      case 'finished': return Icons.check_circle;
      default: return Icons.help;
    }
  }

  Color getStatusColor() {
    switch (rideStatus) {
      case 'in_progress': return const Color(0xFF3B82F6);
      case 'paused': return const Color(0xFFFACC15);
      case 'finished': return const Color(0xFF4CAF50);
      default: return Colors.grey;
    }
  }

  String getStatusLabel() {
    switch (rideStatus) {
      case 'in_progress': return 'En cours';
      case 'paused': return 'En pause';
      case 'finished': return 'Terminé';
      default: return 'Inconnu';
    }
  }

  Color _getSignalColor() {
    if (_isFinished || lastUpdate == null) return const Color(0xFF4ADE80);
    final s = _sinceLastUpdate.inSeconds;
    if (s < 120) return const Color(0xFF4ADE80);
    if (s < 300) return const Color(0xFFFACC15);
    return const Color(0xFFF87171);
  }

  String _getSignalLabel() {
    if (_isFinished || lastUpdate == null) return 'Signal reçu';
    final s = _sinceLastUpdate.inSeconds;
    if (s < 120) return 'Signal reçu';
    if (s < 300) return 'Signal faible';
    return 'Signal perdu';
  }

  Widget _buildSignalIndicator() {
    final color = _getSignalColor();
    return Tooltip(
      message: '< 2 min : Signal reçu\n2–5 min : Signal faible\n> 5 min : Signal perdu',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          Text(_getSignalLabel(), style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _buildVersionBadge() {
    final parts = appVersion.split('+');
    final version = parts.first;
    final rawBuild = parts.length > 1 ? parts[1].split(' ').first : '';
    final build = rawBuild.length == 10
        ? '${rawBuild.substring(0, 8)}.${rawBuild.substring(8)}'
        : rawBuild;
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 3,
            height: 36,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFFFF8A00), Color(0xFF6D28D9)],
              ),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(8),
                bottomLeft: Radius.circular(8),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 10, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(version, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                if (build.isNotEmpty)
                  Text('build $build', style: const TextStyle(color: Colors.white54, fontSize: 10)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<LatLng> get tracePoints {
    return tracePositions.reversed
        .map((p) => LatLng(
              (p['latitude'] as num).toDouble(),
              (p['longitude'] as num).toDouble(),
            ))
        .toList();
  }

  double _haversineMeters(LatLng a, LatLng b) {
    const r = 6371000.0;
    final lat1 = a.latitude * math.pi / 180;
    final lat2 = b.latitude * math.pi / 180;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final sinLat = math.sin(dLat / 2);
    final sinLng = math.sin(dLng / 2);
    final h = sinLat * sinLat + math.cos(lat1) * math.cos(lat2) * sinLng * sinLng;
    return 2 * r * math.asin(math.sqrt(h));
  }

  void _computeStats(List<Map<String, dynamic>> positions) {
    final points = positions.reversed.toList();
    double dist = 0;
    for (int i = 1; i < points.length; i++) {
      final a = LatLng((points[i - 1]['latitude'] as num).toDouble(), (points[i - 1]['longitude'] as num).toDouble());
      final b = LatLng((points[i]['latitude'] as num).toDouble(), (points[i]['longitude'] as num).toDouble());
      dist += _haversineMeters(a, b);
    }
    _totalDistanceMeters = dist;
    if (points.length >= 2) {
      final first = DateTime.tryParse(points.first['created_at'] ?? '');
      final last = DateTime.tryParse(points.last['created_at'] ?? '');
      if (first != null && last != null) _rideDuration = last.difference(first).abs();
    }
  }

  String _formatDistance(double meters) {
    if (meters < 1000) return '${meters.toStringAsFixed(0)} m';
    return '${(meters / 1000).toStringAsFixed(2)} km';
  }

  String _formatDuration(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  String _formatStartTime() {
    if (rideStartTime == null) return '--:--';
    final dt = rideStartTime!.toLocal();
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  void _fitBounds(List<LatLng> points) {
    if (points.isEmpty) return;
    final bounds = LatLngBounds.fromPoints(points);
    mapController.fitCamera(CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(48)));
  }

  void _tryInitialFit() {
    if (!_mapReady || _mapFitDone) return;
    final points = tracePoints;
    if (points.isEmpty) return;
    _fitBounds(points);
    _mapFitDone = true;
  }

  void _recenter() {
    if (latitude == null || longitude == null) return;
    mapController.move(LatLng(latitude!, longitude!), 15);
  }

  void _updateDocumentMeta(String status) {
    try {
      final icon = status == 'finished'
          ? '🟢'
          : status == 'in_progress'
              ? '🔵'
              : status == 'paused'
                  ? '🟡'
                  : '⚪';
      final label = status == 'finished'
          ? 'Ride terminé'
          : status == 'in_progress'
              ? 'En cours'
              : status == 'paused'
                  ? 'En pause'
                  : 'Statut du ride indisponible';
      html.document.title = '$icon $label';
    } catch (_) {}
  }

  void _checkStatusChange(String newStatus) {
    _updateDocumentMeta(newStatus);
    if (_previousRideStatus != null && _previousRideStatus != newStatus) {
      final label = newStatus == 'in_progress' ? 'Le ride a repris ▶'
          : newStatus == 'paused' ? 'Le ride est en pause ⏸'
          : newStatus == 'finished' ? 'Le ride est terminé ✓'
          : 'Statut mis à jour';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(label),
        backgroundColor: getStatusColor(),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
      ));
    }
    _previousRideStatus = newStatus;
  }

  Future<void> loadLastPosition({bool manual = false}) async {
    if (shareCode == null) {
      setState(() { errorMessage = 'missing_code'; isLoading = false; });
      return;
    }
    if (!isLoading) setState(() => isRefreshing = true);
    try {
      final supabase = Supabase.instance.client;
      final session = await supabase.from('safety_sessions').select('id, status, started_at, ride_json').eq('share_code', shareCode!).single();
      final newStatus = session['status'] ?? 'unknown';
      _checkStatusChange(newStatus);
      rideStatus = newStatus;
      rideStartTime = DateTime.tryParse(session['started_at'] ?? '');
      final positions = await supabase.from('safety_positions').select().eq('session_id', session['id']).order('created_at', ascending: false).limit(2500);
      final parsedPositions = List<Map<String, dynamic>>.from(positions);
      if (parsedPositions.isEmpty) {
        setState(() { errorMessage = 'Aucune position disponible'; isLoading = false; isRefreshing = false; });
        return;
      }
      // Les waypoints sont stockés localement sur le téléphone pendant le ride.
      // Ils arrivent dans safety_sessions.ride_json['waypoints'] uniquement à la fin.
      List<Map<String, dynamic>> parsedCheckpoints = [];
      try {
        final rideJson = session['ride_json'] as Map<String, dynamic>?;
        final rawWaypoints = rideJson?['waypoints'] as List<dynamic>?;
        if (rawWaypoints != null) {
          parsedCheckpoints = rawWaypoints
              .whereType<Map<String, dynamic>>()
              .map((w) => {
                    'created_at': w['timestamp'] as String?,
                    'comment': (w['note'] as String? ?? '').isNotEmpty ? w['note'] : null,
                    'photo_url': null, // chemins locaux téléphone — inaccessibles depuis le web
                    'lat': w['lat'],
                    'lng': w['lng'],
                  })
              .toList();
        }
      } catch (_) {}
      _computeStats(parsedPositions);
      final latestPosition = parsedPositions.first;
      setState(() {
        tracePositions = parsedPositions;
        _checkpoints = parsedCheckpoints;
        latitude = (latestPosition['latitude'] as num).toDouble();
        longitude = (latestPosition['longitude'] as num).toDouble();
        lastUpdate = DateTime.tryParse(latestPosition['created_at']);
        isLoading = false;
        isRefreshing = false;
      });
      _stopPollingIfFinished();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!_mapFitDone) {
          _tryInitialFit();
        } else {
          mapController.move(LatLng(latitude!, longitude!), mapController.camera.zoom);
        }
      });
      if (manual) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Position mise à jour'), behavior: SnackBarBehavior.floating, duration: Duration(seconds: 2)));
      }
    } catch (e) {
      setState(() { errorMessage = 'system_error'; errorDetails = e.toString(); isLoading = false; isRefreshing = false; });
    }
  }

  void _showRefreshBottomSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1B1B1B),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Rafraîchissement', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                onPressed: isRefreshing ? null : () { Navigator.pop(context); loadLastPosition(manual: true); },
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2A2A2A), foregroundColor: Colors.white),
                icon: const Icon(Icons.refresh, color: Colors.orange),
                label: const Text('Rafraîchir maintenant'),
              ),
            ),
            const SizedBox(height: 12),
            const Text('Intervalle auto', style: TextStyle(color: Colors.white54, fontSize: 13)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              for (final entry in {0: 'Off', 15: '15 s', 30: '30 s', 60: '60 s'}.entries)
                ChoiceChip(
                  label: Text(entry.value),
                  selected: refreshIntervalSeconds == entry.key,
                  selectedColor: Colors.orange,
                  labelStyle: TextStyle(color: refreshIntervalSeconds == entry.key ? Colors.black : Colors.white70),
                  backgroundColor: const Color(0xFF2A2A2A),
                  onSelected: (_) { Navigator.pop(context); changeRefreshInterval(entry.key); },
                ),
            ]),
          ]),
        ),
      ),
    );
  }

  /// Amélioration 7 : bottom sheet pour choisir l'app de navigation
  void _showNavigationSheet(BuildContext context) {
    final lat = latitude;
    final lng = longitude;
    if (lat == null || lng == null) return;

    final apps = [
      {'label': 'Google Maps', 'icon': Icons.map_outlined, 'url': 'https://www.google.com/maps/search/?api=1&query=$lat,$lng'},
      {'label': 'Waze', 'icon': Icons.navigation_outlined, 'url': 'https://waze.com/ul?ll=$lat,$lng&navigate=yes'},
      {'label': 'Apple Plans', 'icon': Icons.directions_outlined, 'url': 'https://maps.apple.com/?ll=$lat,$lng&q=Position'},
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1B1B1B),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Ouvrir la position dans…', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 16),
            for (final app in apps)
              ListTile(
                leading: Icon(app['icon'] as IconData, color: const Color(0xFFD7B8FF)),
                title: Text(app['label'] as String, style: const TextStyle(color: Colors.white)),
                onTap: () async {
                  Navigator.pop(context);
                  final uri = Uri.parse(app['url'] as String);
                  if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
                },
              ),
          ]),
        ),
      ),
    );
  }

  /// Amélioration 6 : copier le lien de partage dans le presse-papier (web)
  Future<void> _copyShareLink() async {
    try {
      final url = Uri.base.toString();
      final ta = html.document.createElement('textarea') as dynamic;
      ta.value = url;
      html.document.body!.append(ta);
      ta.select();
      html.document.execCommand('copy');
      ta.remove();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('✅ Lien copié dans le presse-papier'),
          backgroundColor: Color(0xFF166534),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 3),
        ));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Impossible de copier le lien'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    }
  }

  Widget _buildMapStyleSelector() {
    return Container(
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.65), borderRadius: BorderRadius.circular(20)),
      padding: const EdgeInsets.all(3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(kMapStyles.length, (i) {
          final style = kMapStyles[i];

          final isActive = i == _mapStyleIndex;
          return GestureDetector(
            onTap: () {
                if (i == _mapStyleIndex) return;
                final newMaxZoom = (kMapStyles[i]['maxZoom'] as int).toDouble();
                // Sauvegarder position courante avant de recréer la carte
                final currentZoom = mapController.camera.zoom;
                final currentCenter = mapController.camera.center;
                setState(() {
                  _mapStyleIndex = i;
                  _savedZoom = currentZoom > newMaxZoom ? newMaxZoom : currentZoom;
                  _savedCenter = currentCenter;
                  mapController = MapController();
                  _mapReady = false;
                });
              },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.symmetric(horizontal: 2),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(color: isActive ? Colors.white : Colors.transparent, borderRadius: BorderRadius.circular(16)),
              child: Row(children: [
                Icon(style['icon'] as IconData, size: 13, color: isActive ? Colors.black : Colors.white70),
                if (isActive) ...[const SizedBox(width: 4), Text(style['label'] as String, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.black))],
              ]),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildMap() {
    final points = tracePoints;
    final currentPosition = LatLng(latitude!, longitude!);
    final gradientColors = _buildGradientColors(points.length);
    return FlutterMap(
        key: ValueKey('map_$_mapStyleIndex'),
        mapController: mapController,
        options: MapOptions(
          initialCenter: _savedCenter ?? currentPosition,
          initialZoom: _savedZoom,
          onMapReady: () {
            _mapReady = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _tryInitialFit();
            });
          },
        ),
        children: [
          TileLayer(urlTemplate: kMapStyles[_mapStyleIndex]['url'] as String, subdomains: kMapStyles[_mapStyleIndex]['subdomains'] as List<String>, maxZoom: (kMapStyles[_mapStyleIndex]['maxZoom'] as int).toDouble(), userAgentPackageName: 'com.example.sunday_tracker_live'),
          if (points.length >= 2)
            PolylineLayer(polylines: List.generate(points.length - 1, (i) => Polyline(points: [points[i], points[i + 1]], strokeWidth: 5, color: gradientColors[i]))),
          MarkerLayer(markers: [
            if (points.isNotEmpty)
              Marker(
                point: points.first, width: 26, height: 26,
                child: Container(
                  decoration: BoxDecoration(color: const Color(0xFFFF8A00), shape: BoxShape.circle, boxShadow: [BoxShadow(color: const Color(0xFFFF8A00).withValues(alpha: 0.6), blurRadius: 8)]),
                  child: const Icon(Icons.play_arrow, color: Colors.white, size: 16),
                ),
              ),
            for (final cp in _checkpoints)
              if (cp['lat'] != null && cp['lng'] != null)
                Marker(
                  point: LatLng((cp['lat'] as num).toDouble(), (cp['lng'] as num).toDouble()),
                  width: 26, height: 26,
                  child: Container(
                    decoration: BoxDecoration(color: const Color(0xFF3B82F6), shape: BoxShape.circle, boxShadow: [BoxShadow(color: const Color(0xFF3B82F6).withValues(alpha: 0.6), blurRadius: 8)]),
                    child: const Icon(Icons.location_on, color: Colors.white, size: 16),
                  ),
                ),
            if (points.length > 1)
              Marker(
                point: points.last, width: 26, height: 26,
                child: Container(
                  decoration: BoxDecoration(color: const Color(0xFF6D28D9), shape: BoxShape.circle, boxShadow: [BoxShadow(color: const Color(0xFF6D28D9).withValues(alpha: 0.6), blurRadius: 8)]),
                  child: const Icon(Icons.sports_score_sharp, color: Colors.white, size: 16),
                ),
              ),
            Marker(point: currentPosition, width: 34, height: 34, child: const Icon(Icons.location_on, color: Colors.red, size: 34)),
          ]),
        ],
    );
  }

  Widget _buildTopOverlay(bool isMobile, double topPadding) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black.withValues(alpha: 0.80), Colors.transparent],
        ),
      ),
      padding: EdgeInsets.fromLTRB(16, topPadding + 12, 12, 28),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Sunday Tracker Live',
                    style: GoogleFonts.robotoCondensed(color: Colors.white, fontSize: isMobile ? 14 : 36, fontWeight: FontWeight.w700, shadows: [const Shadow(color: Colors.black54, blurRadius: 4)])),
                const SizedBox(height: 6),
                _buildVersionBadge(),
              ],
            ),
          ),
          if (!isMobile && !_isFinished) ...[
            if (isRefreshing)
              const Padding(
                padding: EdgeInsets.only(right: 8, top: 2),
                child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.orange)),
              ),
            GestureDetector(
              onTap: isRefreshing ? null : () => loadLastPosition(manual: true),
              child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.refresh, color: Colors.orange, size: 22)),
            ),
            DropdownButtonHideUnderline(child: DropdownButton<int>(
              value: refreshIntervalSeconds,
              dropdownColor: const Color(0xFF1B1B1B),
              iconEnabledColor: Colors.orange,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              items: const [
                DropdownMenuItem(value: 0, child: Text('Off')),
                DropdownMenuItem(value: 15, child: Text('15 s')),
                DropdownMenuItem(value: 30, child: Text('30 s')),
                DropdownMenuItem(value: 60, child: Text('60 s')),
              ],
              onChanged: (v) { if (v != null) changeRefreshInterval(v); },
            )),
            const SizedBox(width: 8),
          ],
          if (isMobile && !_isFinished) ...[
            if (isRefreshing)
              const Padding(
                padding: EdgeInsets.only(right: 4, top: 4),
                child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.orange)),
              ),
            GestureDetector(
              onTap: () => _showRefreshBottomSheet(context),
              child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.more_vert, color: Colors.orange, size: 22)),
            ),
          ],
        ],
      ),
    );
  }

  String _formatUpdateDateFr() {
    if (lastUpdate == null) return '';
    final dt = lastUpdate!.toLocal();
    const months = ['janvier', 'février', 'mars', 'avril', 'mai', 'juin',
                    'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre'];
    return '${dt.day} ${months[dt.month - 1]} ${dt.year}';
  }

  String _formatStartDateFr() {
    if (rideStartTime == null) return '--';
    final dt = rideStartTime!.toLocal();
    const months = ['janvier', 'février', 'mars', 'avril', 'mai', 'juin',
                    'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre'];
    return '${dt.day} ${months[dt.month - 1]} ${dt.year}';
  }

  Widget _buildStatBlock(String label, String value) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 11)),
        const SizedBox(height: 2),
        Text(value, style: const TextStyle(color: Color(0xFFFF8A00), fontSize: 17, fontWeight: FontWeight.bold)),
      ],
    );
  }

  Widget _buildDepartBlock() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Départ', style: TextStyle(color: Colors.white54, fontSize: 11)),
        const SizedBox(height: 2),
        Text(_formatStartDateFr(), style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
        Text(_formatStartTime(), style: const TextStyle(color: Colors.white60, fontSize: 12)),
      ],
    );
  }

  Widget _buildPositionCard() {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: const Color(0xFF1B1B1B),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            const Text('DERNIÈRE POSITION CONNUE',
              style: TextStyle(color: Color(0xFFFF8A00), fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: 1.0)),
            const Spacer(),
            if (rideStatus == 'in_progress' || rideStatus == 'paused')
              _buildSignalIndicator()
            else if (_isFinished)
              _buildStatusPill(),
          ]),
          const SizedBox(height: 6),
          if (!_isFinished) ...[
            _buildStatusPill(),
            const SizedBox(height: 6),
          ],
          Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            const Icon(Icons.location_on, color: Color(0xFFFF8A00), size: 20),
            const SizedBox(width: 8),
            Text(_formatSinceLastUpdate(),
              style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold, height: 1.1)),
          ]),
          if (lastUpdate != null) ...[
            const SizedBox(height: 8),
            Row(children: [
              const Icon(Icons.calendar_today_outlined, color: Colors.white38, size: 12),
              const SizedBox(width: 6),
              Text(_formatUpdateDateFr(), style: const TextStyle(color: Colors.white60, fontSize: 11)),
              const SizedBox(width: 14),
              const Icon(Icons.access_time_outlined, color: Colors.white38, size: 12),
              const SizedBox(width: 6),
              Text(DateFormat('HH:mm:ss').format(lastUpdate!.toLocal()),
                style: const TextStyle(color: Colors.white60, fontSize: 11)),
            ]),
          ],
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              flex: 3,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _showNavigationSheet(context),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  decoration: BoxDecoration(color: const Color(0xFF6D28D9), borderRadius: BorderRadius.circular(10)),
                  child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.map_outlined, color: Colors.white, size: 15),
                    SizedBox(width: 6),
                    Text('Ouvrir la position',
                      style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                  ]),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _copyShareLink,
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  decoration: BoxDecoration(
                    color: const Color(0xFF232323),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.link, color: Colors.white38, size: 14),
                    SizedBox(width: 5),
                    Text('Copier le lien',
                      style: TextStyle(color: Colors.white38, fontSize: 11)),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _buildDesktopBottomBar(double bottomPadding) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 14 + bottomPadding),
      child: IntrinsicHeight(
        child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            decoration: BoxDecoration(
              color: const Color(0xFF1B1B1B),
              borderRadius: BorderRadius.circular(16),
            ),
            child: IntrinsicWidth(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      _buildMapStyleSelector(),
                      const Spacer(),
                      GestureDetector(
                        onTap: () { final pts = tracePoints; if (pts.isNotEmpty) _fitBounds(pts); },
                        child: Container(
                          width: 36, height: 36,
                          decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(10)),
                          child: const Icon(Icons.fit_screen, color: Colors.white, size: 18),
                        ),
                      ),
                      const SizedBox(width: 6),
                      GestureDetector(
                        onTap: _recenter,
                        child: Container(
                          width: 36, height: 36,
                          decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(10)),
                          child: const Icon(Icons.my_location, color: Colors.white, size: 18),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Container(height: 1, color: Colors.white24),
                  const SizedBox(height: 10),
                  IntrinsicHeight(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildStatBlock('Distance', _formatDistance(_totalDistanceMeters)),
                        const SizedBox(width: 12),
                        Container(width: 1, color: Colors.white12),
                        const SizedBox(width: 12),
                        _buildStatBlock('Durée', _formatDuration(_rideDuration)),
                        const SizedBox(width: 12),
                        Container(width: 1, color: Colors.white12),
                        const SizedBox(width: 12),
                        _buildDepartBlock(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Spacer(),
          if (!_waypointsPanelOpen)
            SizedBox(
              width: 440,
              child: _buildPositionCard(),
            ),
        ],
      ),
      ),
    );
  }

  Widget _buildMobileBottomPanel(double bottomPadding) {
    return Padding(
      padding: EdgeInsets.fromLTRB(14, 0, 14, 12 + bottomPadding),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        decoration: BoxDecoration(
          color: const Color(0xFF1B1B1B),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Waypoints trigger
            GestureDetector(
              onTap: () => _showWaypointsBottomSheet(context),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white12),
                ),
                child: Row(children: [
                  const Icon(Icons.route, color: Color(0xFF4F9CFF), size: 14),
                  const SizedBox(width: 8),
                  const Text('Points de passage', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                  const SizedBox(width: 4),
                  Text('· $_waypointCount', style: const TextStyle(color: Colors.white38, fontSize: 12)),
                  const Spacer(),
                  const Icon(Icons.keyboard_arrow_up, color: Colors.white38, size: 18),
                ]),
              ),
            ),
            const SizedBox(height: 8),
            // Controls row
            Row(
              children: [
                _buildMapStyleSelector(),
                const Spacer(),
                if (!_isFinished) ...[
                  GestureDetector(
                    onTap: () => _showRefreshBottomSheet(context),
                    child: Container(
                      width: 36, height: 36,
                      decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(10)),
                      child: isRefreshing
                          ? const Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.orange)))
                          : const Icon(Icons.sync, color: Colors.white, size: 18),
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                GestureDetector(
                  onTap: () { final pts = tracePoints; if (pts.isNotEmpty) _fitBounds(pts); },
                  child: Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(10)),
                    child: const Icon(Icons.fit_screen, color: Colors.white, size: 18),
                  ),
                ),
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: _recenter,
                  child: Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(10)),
                    child: const Icon(Icons.my_location, color: Colors.white, size: 18),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Stats row (sans séparateur au-dessus)
            Row(
              children: [
                Expanded(child: _buildStatBlock('Distance', _formatDistance(_totalDistanceMeters))),
                Container(width: 1, height: 36, color: Colors.white12),
                Expanded(child: Padding(
                  padding: const EdgeInsets.only(left: 14),
                  child: _buildStatBlock('Durée', _formatDuration(_rideDuration)),
                )),
                Container(width: 1, height: 36, color: Colors.white12),
                Expanded(child: Padding(
                  padding: const EdgeInsets.only(left: 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Départ', style: TextStyle(color: Colors.white54, fontSize: 11)),
                      const SizedBox(height: 2),
                      Text(
                        rideStartTime != null ? '${_formatStartDateFr()} • ${_formatStartTime()}' : '--',
                        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                )),
              ],
            ),
            const SizedBox(height: 8),
            Container(height: 1, color: Colors.white12),
            const SizedBox(height: 8),
            // Position header
            Row(children: [
              const Text('DERNIÈRE POSITION CONNUE',
                style: TextStyle(color: Color(0xFFFF8A00), fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: 1.0)),
              const Spacer(),
              if (rideStatus == 'in_progress' || rideStatus == 'paused')
                _buildSignalIndicator()
              else if (_isFinished)
                _buildStatusPill(),
            ]),
            if (!_isFinished) ...[
              const SizedBox(height: 4),
              _buildStatusPill(),
            ],
            const SizedBox(height: 4),
            // Position
            Row(children: [
              const Icon(Icons.location_on, color: Color(0xFFFF8A00), size: 18),
              const SizedBox(width: 6),
              Text(_formatSinceLastUpdate(),
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            ]),
            if (lastUpdate != null) ...[
              const SizedBox(height: 4),
              Row(children: [
                const Icon(Icons.calendar_today_outlined, color: Colors.white38, size: 12),
                const SizedBox(width: 5),
                Text(_formatUpdateDateFr(), style: const TextStyle(color: Colors.white60, fontSize: 11)),
                const SizedBox(width: 10),
                const Icon(Icons.access_time_outlined, color: Colors.white38, size: 12),
                const SizedBox(width: 5),
                Text(DateFormat('HH:mm:ss').format(lastUpdate!.toLocal()),
                  style: const TextStyle(color: Colors.white60, fontSize: 11)),
              ]),
            ],
            const SizedBox(height: 8),
            // Boutons
            Row(children: [
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _showNavigationSheet(context),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(color: const Color(0xFF6D28D9), borderRadius: BorderRadius.circular(10)),
                    child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(Icons.map_outlined, color: Colors.white, size: 15),
                      SizedBox(width: 6),
                      Text('Ouvrir la position', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                    ]),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _copyShareLink,
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF232323),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: const Icon(Icons.link, color: Colors.white38, size: 18),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorScreen() {
    final isMissingCode = errorMessage == 'missing_code';
    final isNoPosition = errorMessage == 'Aucune position disponible';
    final isSystemError = errorMessage == 'system_error';
    final IconData icon = isMissingCode ? Icons.link_off : isNoPosition ? Icons.location_off : Icons.cloud_off;
    final Color iconBg = isMissingCode ? const Color(0xFF2D2010) : isNoPosition ? const Color(0xFF1A2030) : const Color(0xFF2A1A1A);
    final Color iconColor = isMissingCode ? const Color(0xFFFACC15) : isNoPosition ? const Color(0xFF60A5FA) : const Color(0xFFF87171);
    final String title = isMissingCode ? 'Lien de partage invalide' : isNoPosition ? 'Aucune position disponible' : 'Impossible de charger le ride';
    final String subtitle = isMissingCode
        ? 'Ce lien ne contient pas de code de ride. Il a peut-être expiré, été mal copié, ou tu l\'as ouvert directement sans paramètre.'
        : isNoPosition ? 'Le ride existe mais aucune position GPS n\'a encore été enregistrée. Attends quelques secondes et rafraîchis la page.'
        : 'Une erreur s\'est produite lors de la connexion au serveur. Vérifie ta connexion internet et réessaie.';

    return Column(children: [
      Expanded(child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
        const SizedBox(height: 40),
        Container(width: 80, height: 80, decoration: BoxDecoration(color: iconBg, shape: BoxShape.circle), child: Icon(icon, color: iconColor, size: 36)),
        const SizedBox(height: 24),
        Text(title, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600), textAlign: TextAlign.center),
        const SizedBox(height: 12),
        Text(subtitle, style: const TextStyle(color: Colors.white60, fontSize: 15, height: 1.6), textAlign: TextAlign.center),
        const SizedBox(height: 32),
        if (isMissingCode)
          Container(width: double.infinity, padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: const Color(0xFF1B1B1B), borderRadius: BorderRadius.circular(16)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Comment obtenir un lien valide ?', style: TextStyle(color: Colors.white54, fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 14),
            _buildStep(1, 'Ouvre l\'application Sunday Tracker sur ton téléphone'),
            const SizedBox(height: 10),
            _buildStep(2, 'Lance ou sélectionne un ride en cours'),
            const SizedBox(height: 10),
            _buildStep(3, 'Appuie sur Partager le suivi pour générer ton lien'),
          ])),
        if (!isMissingCode) ...[
          SizedBox(width: double.infinity, child: ElevatedButton.icon(
            onPressed: () { setState(() { errorMessage = null; errorDetails = null; isLoading = true; }); loadLastPosition(); },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1B1B1B), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30))),
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Réessayer'),
          )),
        ],
        if (isSystemError && errorDetails != null) ...[
          const SizedBox(height: 16),
          GestureDetector(
            onTap: () => setState(() => _errorDetailsExpanded = !_errorDetailsExpanded),
            child: Container(width: double.infinity, decoration: BoxDecoration(color: const Color(0xFF1B1B1B), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.white.withValues(alpha: 0.08))), child: Column(children: [
              Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), child: Row(children: [
                const Icon(Icons.bug_report_outlined, color: Colors.white60, size: 16),
                const SizedBox(width: 8),
                const Expanded(child: Text('Voir les détails techniques', style: TextStyle(color: Colors.white60, fontSize: 13))),
                Icon(_errorDetailsExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, color: Colors.white60, size: 18),
              ])),
              if (_errorDetailsExpanded)
                Container(width: double.infinity, padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), child: Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: const Color(0xFF111111), borderRadius: BorderRadius.circular(8)), child: SelectableText(errorDetails!, style: const TextStyle(color: Colors.white54, fontSize: 11, fontFamily: 'monospace', height: 1.6)))),
            ])),
          ),
        ],
      ]))),
      Padding(padding: const EdgeInsets.only(bottom: 16), child: Text(appVersion, style: const TextStyle(color: Colors.white38, fontSize: 11))),
    ]);
  }

  Widget _buildStep(int number, String text) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(width: 22, height: 22, decoration: const BoxDecoration(color: Color(0xFF1E3A5F), shape: BoxShape.circle), child: Center(child: Text('$number', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF60A5FA))))),
      const SizedBox(width: 12),
      Expanded(child: Text(text, style: const TextStyle(color: Colors.white60, fontSize: 13, height: 1.5))),
    ]);
  }

  // ── Waypoints ─────────────────────────────────────────────────────────────

  int get _waypointCount {
    int n = 0;
    if (tracePositions.isNotEmpty) n++;
    n += _checkpoints.length;
    if (tracePositions.length > 1 || _isFinished) n++;
    return n;
  }

  Widget _buildTimelinePoint({
    required String type,
    required String label,
    DateTime? time,
    String? comment,
    String? photoUrl,
    required bool isLast,
  }) {
    final Color dotColor;
    final Widget dotInner;
    switch (type) {
      case 'start':
        dotColor = const Color(0xFFFF8A00);
        dotInner = const Icon(Icons.play_arrow, color: Colors.white, size: 12);
        break;
      case 'end':
        dotColor = const Color(0xFF6D28D9);
        dotInner = const Icon(Icons.sports_score_sharp, color: Colors.white, size: 12);
        break;
      case 'current':
        dotColor = const Color(0xFF4ADE80);
        dotInner = const Icon(Icons.location_on, color: Colors.white, size: 12);
        break;
      default:
        dotColor = const Color(0xFF3B82F6);
        dotInner = const Icon(Icons.location_on, color: Colors.white, size: 12);
    }
    final timeStr = time != null
        ? '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}'
        : '--:--';

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 26,
            child: Column(
              children: [
                Container(
                  width: 22, height: 22,
                  decoration: BoxDecoration(
                    color: dotColor,
                    shape: BoxShape.circle,
                  ),
                  child: Center(child: dotInner),
                ),
                if (!isLast)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Center(child: Container(width: 2, color: Colors.white12)),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(top: 1, bottom: isLast ? 0 : 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(children: [
                    Expanded(child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700))),
                    Text(timeStr, style: const TextStyle(color: Colors.white38, fontSize: 11)),
                  ]),
                  if (comment != null && comment.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(comment, style: const TextStyle(color: Colors.white60, fontSize: 12, height: 1.4)),
                  ],
                  if (photoUrl != null && photoUrl.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(
                        photoUrl, height: 80, width: double.infinity, fit: BoxFit.cover,
                        errorBuilder: (context, error, stack) => const SizedBox.shrink(),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWaypointTimeline() {
    if (tracePositions.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('Aucun point disponible', style: TextStyle(color: Colors.white38, fontSize: 13)),
      );
    }

    final departurePos = tracePositions.last;
    final latestPos = tracePositions.first;
    final departureTime = DateTime.tryParse(departurePos['created_at'] ?? '')?.toLocal();
    final latestTime = DateTime.tryParse(latestPos['created_at'] ?? '')?.toLocal();
    final hasEndPoint = tracePositions.length > 1 || _isFinished;
    final total = 1 + _checkpoints.length + (hasEndPoint ? 1 : 0);
    int idx = 0;

    final widgets = <Widget>[];

    widgets.add(_buildTimelinePoint(
      type: 'start', label: 'Départ', time: departureTime,
      isLast: ++idx == total,
    ));

    for (final cp in _checkpoints) {
      final dt = DateTime.tryParse(cp['created_at'] ?? '')?.toLocal();
      widgets.add(_buildTimelinePoint(
        type: 'checkpoint', label: 'Point mémorisé', time: dt,
        comment: cp['comment'] as String?,
        photoUrl: cp['photo_url'] as String?,
        isLast: ++idx == total,
      ));
    }

    if (hasEndPoint) {
      widgets.add(_buildTimelinePoint(
        type: _isFinished ? 'end' : 'current',
        label: _isFinished ? 'Arrivée' : 'Dernière position',
        time: latestTime,
        isLast: true,
      ));
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: widgets);
  }

  void _showWaypointsBottomSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.45,
        minChildSize: 0.22,
        maxChildSize: 0.88,
        snap: true,
        snapSizes: const [0.22, 0.45, 0.88],
        builder: (ctx, scrollCtrl) => Container(
          decoration: const BoxDecoration(
            color: Color(0xFF18181B),
            borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
          ),
          child: Column(children: [
            const SizedBox(height: 10),
            Container(width: 48, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(999))),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(children: [
                const Text('Points de passage', style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(width: 6),
                Text('· $_waypointCount', style: const TextStyle(color: Colors.white38, fontSize: 14, fontWeight: FontWeight.w600)),
                const Spacer(),
                GestureDetector(
                  onTap: () => Navigator.pop(ctx),
                  child: Container(
                    width: 28, height: 28,
                    decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(8)),
                    child: const Icon(Icons.close, color: Colors.white60, size: 15),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 14),
            Expanded(
              child: SingleChildScrollView(
                controller: scrollCtrl,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                child: _buildWaypointTimeline(),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _buildWaypointsTab() {
    return GestureDetector(
      onTap: () => setState(() => _waypointsPanelOpen = true),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF1B1B1B),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(10),
            bottomLeft: Radius.circular(10),
          ),
          border: Border.all(color: Colors.white12),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 12)],
        ),
        child: RotatedBox(
          quarterTurns: 3,
          child: Text(
            'Points de passage · $_waypointCount',
            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.2),
          ),
        ),
      ),
    );
  }

  Widget _buildDesktopWaypointsPanel(double topPadding, double bottomPadding) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0D0D0D).withValues(alpha: 0.96),
        border: const Border(left: BorderSide(color: Colors.white12)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 20, offset: const Offset(-4, 0))],
      ),
      child: Column(children: [
        SizedBox(height: topPadding + 12),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
          child: Row(children: [
            const Text('Points de passage', style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
            const SizedBox(width: 6),
            Text('· $_waypointCount', style: const TextStyle(color: Colors.white38, fontSize: 14, fontWeight: FontWeight.w600)),
            const Spacer(),
            GestureDetector(
              onTap: () => setState(() => _waypointsPanelOpen = false),
              child: Container(
                width: 28, height: 28,
                decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(8)),
                child: const Icon(Icons.close, color: Colors.white60, size: 15),
              ),
            ),
          ]),
        ),
        Container(height: 1, color: Colors.white12),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
            child: _buildWaypointTimeline(),
          ),
        ),
        Container(height: 1, color: Colors.white12),
        Padding(
          padding: EdgeInsets.fromLTRB(14, 12, 14, 14 + bottomPadding),
          child: _buildPositionCard(),
        ),
      ]),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (isLoading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (errorMessage != null || latitude == null || longitude == null) {
      return Scaffold(backgroundColor: const Color(0xFF0D0D0D), body: SafeArea(child: _buildErrorScreen()));
    }
    final screenSize = MediaQuery.sizeOf(context);
    final isMobileLayout = screenSize.width < 900;
    final topPadding = MediaQuery.of(context).padding.top;
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildMap(),
          Positioned(
            top: 0, left: 0, right: 0,
            child: _buildTopOverlay(isMobileLayout, topPadding),
          ),
          Positioned(
            bottom: 0, left: 0, right: 0,
            child: isMobileLayout
                ? _buildMobileBottomPanel(bottomPadding)
                : _buildDesktopBottomBar(bottomPadding),
          ),
          // Desktop: tab repliable + panel droit
          if (!isMobileLayout) ...[
            Positioned(
              right: 0,
              top: topPadding + 80,
              child: IgnorePointer(
                ignoring: _waypointsPanelOpen,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 200),
                  opacity: _waypointsPanelOpen ? 0.0 : 1.0,
                  child: _buildWaypointsTab(),
                ),
              ),
            ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeInOut,
              top: 0,
              bottom: 0,
              right: _waypointsPanelOpen ? 0 : -340,
              width: 340,
              child: _buildDesktopWaypointsPanel(topPadding, bottomPadding),
            ),
          ],
        ],
      ),
    );
  }
}
