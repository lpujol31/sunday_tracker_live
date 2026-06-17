import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:intl/intl.dart';

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

  final MapController mapController = MapController();
  int _mapStyleIndex = 0;
  bool _mapFitDone = false;

  Timer? refreshTimer;
  int refreshIntervalSeconds = 30;

  final shareCode = Uri.base.queryParameters['code'];

  @override
  void initState() {
    super.initState();
    loadAppVersion();
    loadLastPosition();
    startAutoRefresh();
    _tickerTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (lastUpdate != null) {
        setState(() {
          _sinceLastUpdate = DateTime.now().difference(lastUpdate!);
        });
      }
    });
  }

  @override
  void dispose() {
    refreshTimer?.cancel();
    _tickerTimer?.cancel();
    super.dispose();
  }

  void startAutoRefresh() {
    refreshTimer?.cancel();
    if (refreshIntervalSeconds == 0) return;
    refreshTimer = Timer.periodic(
      Duration(seconds: refreshIntervalSeconds),
      (_) => loadLastPosition(),
    );
  }

  void changeRefreshInterval(int seconds) {
    setState(() => refreshIntervalSeconds = seconds);
    startAutoRefresh();
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

  String _formatSinceLastUpdate() {
    final s = _sinceLastUpdate.inSeconds;
    if (s < 60) return 'il y a ${s}s';
    final m = _sinceLastUpdate.inMinutes;
    if (m < 60) return 'il y a ${m} min';
    final h = _sinceLastUpdate.inHours;
    final rem = m - h * 60;
    return 'il y a ${h}h${rem.toString().padLeft(2, '0')}';
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

  void _recenter() {
    if (latitude == null || longitude == null) return;
    mapController.move(LatLng(latitude!, longitude!), 15);
  }

  void _checkStatusChange(String newStatus) {
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
      final session = await supabase.from('safety_sessions').select('id, status, started_at').eq('share_code', shareCode!).single();
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
      _computeStats(parsedPositions);
      final latestPosition = parsedPositions.first;
      setState(() {
        tracePositions = parsedPositions;
        latitude = (latestPosition['latitude'] as num).toDouble();
        longitude = (latestPosition['longitude'] as num).toDouble();
        lastUpdate = DateTime.tryParse(latestPosition['created_at']);
        isLoading = false;
        isRefreshing = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final points = tracePoints;
        if (points.isEmpty) return;
        if (!_mapFitDone) { _fitBounds(points); _mapFitDone = true; }
        else { mapController.move(LatLng(latitude!, longitude!), mapController.camera.zoom); }
      });
      if (manual) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Position mise à jour'), behavior: SnackBarBehavior.floating, duration: Duration(seconds: 2)));
      }
    } catch (e) {
      setState(() { errorMessage = 'system_error'; errorDetails = e.toString(); isLoading = false; isRefreshing = false; });
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
            onTap: () => setState(() => _mapStyleIndex = i),
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
      mapController: mapController,
      options: MapOptions(initialCenter: currentPosition, initialZoom: 15),
      children: [
        TileLayer(key: ValueKey(_mapStyleIndex), urlTemplate: kMapStyles[_mapStyleIndex]['url'] as String, subdomains: kMapStyles[_mapStyleIndex]['subdomains'] as List<String>, maxZoom: (kMapStyles[_mapStyleIndex]['maxZoom'] as int).toDouble(), userAgentPackageName: 'com.example.sunday_tracker_live'),
        if (points.length >= 2)
          PolylineLayer(polylines: List.generate(points.length - 1, (i) => Polyline(points: [points[i], points[i + 1]], strokeWidth: 5, color: gradientColors[i]))),
        MarkerLayer(markers: [
          if (points.isNotEmpty)
            Marker(point: points.first, width: 22, height: 22, child: Container(decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.25), shape: BoxShape.circle, border: Border.all(color: const Color(0xFFFF8A00), width: 2), boxShadow: [BoxShadow(color: const Color(0xFFFF8A00).withValues(alpha: 0.85), blurRadius: 8)]))),
          if (points.length > 1)
            Marker(point: points.last, width: 26, height: 26, child: Container(decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.25), shape: BoxShape.circle, border: Border.all(color: const Color(0xFF6D28D9), width: 2), boxShadow: [BoxShadow(color: const Color(0xFF6D28D9).withValues(alpha: 0.85), blurRadius: 8)]), child: const Icon(Icons.sports_score_sharp, color: Colors.white, size: 18))),
          Marker(point: currentPosition, width: 34, height: 34, child: const Icon(Icons.location_on, color: Colors.red, size: 34)),
        ]),
      ],
    );
  }

  Widget _buildStatsCard() {
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 700;
    final staleMins = _sinceLastUpdate.inMinutes;
    final staleColor = staleMins >= 10 ? const Color(0xFFF87171) : staleMins >= 5 ? const Color(0xFFFACC15) : const Color(0xFFFF8A00);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: isMobile ? 16 : 24, vertical: isMobile ? 14 : 18),
      decoration: BoxDecoration(color: const Color(0xFF1F1F1F), borderRadius: BorderRadius.circular(20)),
      child: isMobile
          ? Column(children: [
              Row(children: [Expanded(child: _StatItem(icon: Icons.straighten, label: 'Distance', value: _formatDistance(_totalDistanceMeters))), Expanded(child: _StatItem(icon: Icons.timer_outlined, label: 'Durée', value: _formatDuration(_rideDuration)))]),
              const SizedBox(height: 12),
              Row(children: [Expanded(child: _StatItem(icon: Icons.flag_outlined, label: 'Départ', value: _formatStartTime())), Expanded(child: _StatItem(icon: Icons.my_location, label: 'Dernière pos.', value: _formatSinceLastUpdate(), valueColor: staleColor))]),
            ])
          : Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
              _StatItem(icon: Icons.straighten, label: 'Distance', value: _formatDistance(_totalDistanceMeters)),
              _divider(),
              _StatItem(icon: Icons.timer_outlined, label: 'Durée', value: _formatDuration(_rideDuration)),
              _divider(),
              _StatItem(icon: Icons.flag_outlined, label: 'Départ', value: _formatStartTime()),
              _divider(),
              _StatItem(icon: Icons.my_location, label: 'Dernière pos.', value: _formatSinceLastUpdate(), valueColor: staleColor),
            ]),
    );
  }

  Widget _divider() => Container(width: 1, height: 36, color: Colors.white12);

  Widget _buildLocationCard() {
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 700;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (!isMobile) ...[
        Container(width: 72, height: 72, decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), gradient: LinearGradient(colors: [Colors.orange.withValues(alpha: 0.25), Colors.orange.withValues(alpha: 0.08)], begin: Alignment.topLeft, end: Alignment.bottomRight)), child: const Icon(Icons.location_on, color: Colors.orange, size: 40)),
        const SizedBox(width: 16),
      ],
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(width: 4, height: isMobile ? 44 : 52, decoration: BoxDecoration(color: Colors.orange, borderRadius: BorderRadius.circular(20))),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Dernière position connue', style: TextStyle(fontSize: isMobile ? 17 : 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('Latitude : ${latitude?.toStringAsFixed(6)}', style: TextStyle(fontSize: isMobile ? 14 : 16)),
            Text('Longitude : ${longitude?.toStringAsFixed(6)}', style: TextStyle(fontSize: isMobile ? 14 : 16)),
          ])),
        ]),
        const SizedBox(height: 16),
        SizedBox(
          width: isMobile ? double.infinity : null,
          child: ElevatedButton.icon(
            onPressed: () async {
              final uri = Uri.parse('https://www.google.com/maps/search/?api=1&query=$latitude,$longitude');
              if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2B2035), foregroundColor: const Color(0xFFD7B8FF), padding: EdgeInsets.symmetric(horizontal: isMobile ? 14 : 18, vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30))),
            icon: const Icon(Icons.map),
            label: Text(isMobile ? 'Google Maps' : 'Ouvrir dans Google Maps'),
          ),
        ),
        const SizedBox(height: 14),
        Row(children: [
          const Icon(Icons.access_time, color: Colors.white54, size: 16),
          const SizedBox(width: 8),
          Expanded(child: Text(lastUpdate == null ? 'Dernière mise à jour inconnue' : 'Dernière mise à jour : ${DateFormat('dd/MM/yyyy HH:mm:ss').format(lastUpdate!.toLocal())}', style: const TextStyle(color: Colors.white70, fontSize: 12))),
        ]),
      ])),
    ]);
  }

  Widget _buildStatusCard() {
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 700;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: isMobile ? 16 : 26, vertical: isMobile ? 18 : 22),
      decoration: BoxDecoration(color: const Color(0xFF1F1F1F), borderRadius: BorderRadius.circular(24), border: Border.all(color: getStatusColor(), width: 2), boxShadow: [BoxShadow(color: getStatusColor().withValues(alpha: 0.18), blurRadius: 18, spreadRadius: 1)]),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Container(width: isMobile ? 64 : 92, height: isMobile ? 64 : 92, decoration: BoxDecoration(shape: BoxShape.circle, color: getStatusColor().withValues(alpha: 0.12), border: Border.all(color: getStatusColor().withValues(alpha: 0.45), width: 2)), child: Icon(getStatusIcon(), color: getStatusColor(), size: isMobile ? 36 : 54)),
        SizedBox(width: isMobile ? 16 : 24),
        Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('STATUT DU RIDE', style: TextStyle(color: Colors.white.withValues(alpha: 0.65), fontSize: isMobile ? 11 : 13, fontWeight: FontWeight.w600, letterSpacing: 1.2)),
          const SizedBox(height: 6),
          Text(getStatusLabel(), style: TextStyle(color: getStatusColor(), fontSize: isMobile ? 24 : 36, fontWeight: FontWeight.bold)),
          const SizedBox(height: 14),
          Container(height: 1, color: Colors.white.withValues(alpha: 0.08)),
          const SizedBox(height: 14),
          Row(children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(color: getStatusColor(), shape: BoxShape.circle)),
            const SizedBox(width: 10),
            Expanded(child: Text(rideStatus == 'in_progress' ? 'Le ride est actuellement en cours' : rideStatus == 'paused' ? 'Le ride est actuellement en pause' : rideStatus == 'finished' ? 'Le ride est terminé' : 'Statut indisponible', style: TextStyle(color: Colors.white.withValues(alpha: 0.78), fontSize: isMobile ? 13 : 15))),
          ]),
        ])),
      ]),
    );
  }

  Widget _buildBottomPanel() {
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 700;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(isMobile ? 14 : 20),
      color: const Color(0xFF1B1B1B),
      child: LayoutBuilder(builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 900;
        if (isNarrow) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [_buildStatsCard(), const SizedBox(height: 12), _buildLocationCard(), const SizedBox(height: 16), _buildStatusCard()]);
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _buildStatsCard(),
          const SizedBox(height: 16),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(flex: 2, child: _buildLocationCard()), const SizedBox(width: 20), Expanded(child: _buildStatusCard())]),
        ]);
      }),
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
                const Icon(Icons.bug_report_outlined, color: Colors.white38, size: 16),
                const SizedBox(width: 8),
                const Expanded(child: Text('Voir les détails techniques', style: TextStyle(color: Colors.white38, fontSize: 13))),
                Icon(_errorDetailsExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, color: Colors.white38, size: 18),
              ])),
              if (_errorDetailsExpanded)
                Container(width: double.infinity, padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), child: Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: const Color(0xFF111111), borderRadius: BorderRadius.circular(8)), child: SelectableText(errorDetails!, style: const TextStyle(color: Colors.white54, fontSize: 11, fontFamily: 'monospace', height: 1.6)))),
            ])),
          ),
        ],
      ]))),
      Padding(padding: const EdgeInsets.only(bottom: 16), child: Text(appVersion, style: const TextStyle(color: Colors.white24, fontSize: 11))),
    ]);
  }

  Widget _buildStep(int number, String text) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(width: 22, height: 22, decoration: const BoxDecoration(color: Color(0xFF1E3A5F), shape: BoxShape.circle), child: Center(child: Text('$number', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF60A5FA))))),
      const SizedBox(width: 12),
      Expanded(child: Text(text, style: const TextStyle(color: Colors.white60, fontSize: 13, height: 1.5))),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (errorMessage != null || latitude == null || longitude == null) {
      return Scaffold(backgroundColor: const Color(0xFF0D0D0D), body: SafeArea(child: _buildErrorScreen()));
    }
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        title: const Text('Sunday Tracker Live'),
        actions: [
          if (isRefreshing) const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.orange)))),
          IconButton(icon: const Icon(Icons.refresh, color: Colors.orange), tooltip: 'Rafraîchir maintenant', onPressed: isRefreshing ? null : () => loadLastPosition(manual: true)),
          Row(children: [
            const Text('Auto', style: TextStyle(color: Colors.white70, fontSize: 14)),
            const SizedBox(width: 8),
            DropdownButtonHideUnderline(child: DropdownButton<int>(
              value: refreshIntervalSeconds,
              dropdownColor: const Color(0xFF1B1B1B),
              iconEnabledColor: Colors.orange,
              style: const TextStyle(color: Colors.white),
              items: const [DropdownMenuItem(value: 0, child: Text('Off')), DropdownMenuItem(value: 15, child: Text('15 s')), DropdownMenuItem(value: 30, child: Text('30 s')), DropdownMenuItem(value: 60, child: Text('60 s'))],
              onChanged: (value) { if (value == null) return; changeRefreshInterval(value); },
            )),
            const SizedBox(width: 12),
          ]),
        ],
      ),
      body: SafeArea(top: false, child: Column(children: [
        Expanded(child: Stack(children: [
          _buildMap(),
          Positioned(bottom: 16, left: 16, child: _buildMapStyleSelector()),
          Positioned(bottom: 16, right: 16, child: GestureDetector(onTap: _recenter, child: Container(width: 40, height: 40, decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.65), borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.my_location, color: Colors.white, size: 20)))),
        ])),
        _buildBottomPanel(),
        const SizedBox(height: 8),
        Text(appVersion, style: const TextStyle(fontSize: 12, color: Colors.white38)),
      ])),
    );
  }
}

class _StatItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;
  const _StatItem({required this.icon, required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    final color = valueColor ?? const Color(0xFFFF8A00);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, color: color, size: 18),
      const SizedBox(height: 4),
      Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color)),
      const SizedBox(height: 2),
      Text(label, style: const TextStyle(fontSize: 11, color: Colors.white38)),
    ]);
  }
}
