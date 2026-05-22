import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:intl/intl.dart';

const supabaseUrl = 'https://eltlnrxiuvixjlakjfhz.supabase.co';
const supabaseAnonKey =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImVsdGxucnhpdXZpeGpsYWtqZmh6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzkyMDIxMTIsImV4cCI6MjA5NDc3ODExMn0.Udyy_6xF09JArDODJNkF-b-idlw4P-52ByzHilOOwwQ';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: supabaseUrl,
    anonKey: supabaseAnonKey,
  );

  runApp(const SundayTrackerLiveApp());
}

class SundayTrackerLiveApp extends StatelessWidget {
  const SundayTrackerLiveApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Sunday Tracker Live',
      theme: ThemeData.dark(),
      home: const LivePage(),
    );
  }
}

class LivePage extends StatefulWidget {
  const LivePage({super.key});

  @override
  State<LivePage> createState() => _LivePageState();
}

class _LivePageState extends State<LivePage> {
  bool isLoading = true;
  String? errorMessage;

  double? latitude;
  double? longitude;
  DateTime? lastUpdate;

  String appVersion = '';

  Timer? refreshTimer;
  int refreshIntervalSeconds = 30;

  final MapController mapController = MapController();
  final shareCode = Uri.base.queryParameters['code'];

  String rideStatus = 'unknown';

  List<Map<String, dynamic>> tracePositions = [];

  @override
  void initState() {
    super.initState();

    loadAppVersion();
    loadLastPosition();
    startAutoRefresh();
  }

  @override
  void dispose() {
    refreshTimer?.cancel();
    super.dispose();
  }

  void startAutoRefresh() {
    refreshTimer?.cancel();

    if (refreshIntervalSeconds == 0) {
      return;
    }

    refreshTimer = Timer.periodic(
      Duration(seconds: refreshIntervalSeconds),
      (timer) {
        loadLastPosition();
      },
    );
  }

  void changeRefreshInterval(int seconds) {
    setState(() {
      refreshIntervalSeconds = seconds;
    });

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
      case 'in_progress':
        return Icons.play_circle;
      case 'paused':
        return Icons.pause_circle;
      case 'finished':
        return Icons.check_circle;
      default:
        return Icons.help;
    }
  }

  Color getStatusColor() {
    switch (rideStatus) {
      case 'in_progress':
        return const Color(0xFF3B82F6); // bleu

      case 'paused':
        return const Color(0xFFFACC15); // jaune

      case 'finished':
        return const Color(0xFF4CAF50); // vert

      default:
        return Colors.grey;
    }
  }
  String getStatusLabel() {
    switch (rideStatus) {
      case 'in_progress':
        return 'En cours';
      case 'paused':
        return 'En pause';
      case 'finished':
        return 'Terminé';
      default:
        return 'Inconnu';
    }
  }

  List<LatLng> get tracePoints {
    return tracePositions
        .reversed
        .map(
          (position) => LatLng(
            (position['latitude'] as num).toDouble(),
            (position['longitude'] as num).toDouble(),
          ),
        )
        .toList();
  }

  double getBearing(LatLng start, LatLng end) {
    final startLat = start.latitude * math.pi / 180;
    final startLng = start.longitude * math.pi / 180;
    final endLat = end.latitude * math.pi / 180;
    final endLng = end.longitude * math.pi / 180;

    final dLng = endLng - startLng;

    final y = math.sin(dLng) * math.cos(endLat);
    final x = math.cos(startLat) * math.sin(endLat) -
        math.sin(startLat) * math.cos(endLat) * math.cos(dLng);

    return math.atan2(y, x);
  }

  List<Marker> buildDirectionMarkers() {
    final points = tracePoints;

    if (points.length < 4) {
      return [];
    }

    const maxArrows = 3;
    final arrowCount = math.min(maxArrows, points.length - 2);

    final markers = <Marker>[];

    for (int arrowIndex = 1; arrowIndex <= arrowCount; arrowIndex++) {
      final i = ((points.length - 1) * arrowIndex / (arrowCount + 1)).round();

      if (i <= 0 || i >= points.length - 1) {
        continue;
      }

      final start = points[i - 1];
      final end = points[i + 1];

      final middle = points[i];
      final angle = getBearing(start, end);

      markers.add(
        Marker(
          point: middle,
          width: 28,
          height: 28,
          child: Transform.rotate(
            angle: angle,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.navigation,
                color: Colors.white,
                size: 18,
              ),
            ),
          ),
        ),
      );
    }

    return markers;
  }
  Marker buildCurrentPositionMarker(LatLng currentPosition) {
    return Marker(
      point: currentPosition,
      width: 42,
      height: 42,
      child: const Icon(
        Icons.location_on,
        color: Colors.red,
        size: 42,
      ),
    );
  }

  Future<void> loadLastPosition() async {
    if (shareCode == null) {
      setState(() {
        errorMessage = 'Code de partage manquant.';
        isLoading = false;
      });

      return;
    }

    try {
      final supabase = Supabase.instance.client;

      final session = await supabase
          .from('safety_sessions')
          .select('id, status')
          .eq('share_code', shareCode!)
          .single();

      rideStatus = session['status'] ?? 'unknown';

      final positions = await supabase
          .from('safety_positions')
          .select()
          .eq('session_id', session['id'])
          .order('created_at', ascending: false)
          .limit(250);

      final parsedPositions = List<Map<String, dynamic>>.from(positions);

      if (parsedPositions.isEmpty) {
        setState(() {
          errorMessage = 'Aucune position disponible';
          isLoading = false;
        });

        return;
      }

      final latestPosition = parsedPositions.first;

      setState(() {
        tracePositions = parsedPositions;

        latitude = (latestPosition['latitude'] as num).toDouble();
        longitude = (latestPosition['longitude'] as num).toDouble();

        lastUpdate = DateTime.tryParse(
          latestPosition['created_at'],
        );

        isLoading = false;
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (latitude == null || longitude == null) {
          return;
        }

        mapController.move(
          LatLng(latitude!, longitude!),
          mapController.camera.zoom,
        );
      });
    } catch (e) {
      print('ERREUR SUPABASE LIVE: $e');

      setState(() {
        errorMessage = 'Impossible de récupérer la position : $e';
        isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    if (errorMessage != null || latitude == null || longitude == null) {
      return Scaffold(
        backgroundColor: const Color(0xFF0D0D0D),
        body: SafeArea(
          child: Column(
            children: [
              const Spacer(),
              Center(
                child: Text(
                  errorMessage ?? 'Aucune position disponible',
                  style: const TextStyle(
                    color: Colors.white,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.only(
                  bottom: 12,
                ),
                child: Text(
                  appVersion,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final currentPosition = LatLng(
      latitude!,
      longitude!,
    );

    final firstPoint = tracePoints.isNotEmpty
        ? tracePoints.first
        : currentPosition;

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        title: const Text(
          'Sunday Tracker Live',
        ),
        actions: [
          Row(
            children: [
              const Icon(
                Icons.refresh,
                color: Colors.orange,
                size: 20,
              ),
              const SizedBox(width: 6),
              const Text(
                'Auto',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                ),
              ),
              const SizedBox(width: 8),
              DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  value: refreshIntervalSeconds,
                  dropdownColor: const Color(0xFF1B1B1B),
                  iconEnabledColor: Colors.orange,
                  style: const TextStyle(
                    color: Colors.white,
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 0,
                      child: Text('Off'),
                    ),
                    DropdownMenuItem(
                      value: 15,
                      child: Text('15 s'),
                    ),
                    DropdownMenuItem(
                      value: 30,
                      child: Text('30 s'),
                    ),
                    DropdownMenuItem(
                      value: 60,
                      child: Text('60 s'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value == null) {
                      return;
                    }

                    changeRefreshInterval(value);
                  },
                ),
              ),
              const SizedBox(width: 12),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: FlutterMap(
              mapController: mapController,
              options: MapOptions(
                initialCenter: currentPosition,
                initialZoom: 15,
              ),
              children: [
                TileLayer(
                  urlTemplate:
                      'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName:
                      'com.example.sunday_tracker_live',
                ),

                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: tracePoints,
                      strokeWidth: 5,
                      color: Colors.orange,
                    ),
                  ],
                ),

                MarkerLayer(
                  markers: [
                    ...buildDirectionMarkers(),

                    Marker(
                      point: firstPoint,
                      width: 22,
                      height: 22,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.25),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.white,
                            width: 2,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color:
                                  Colors.greenAccent.withValues(alpha: 0.85),
                              blurRadius: 8,
                            ),
                          ],
                        ),
                      ),
                    ),

                    Marker(
                      point: currentPosition,
                      width: 34,
                      height: 34,
                      child: const Icon(
                        Icons.location_on,
                        color: Colors.red,
                        size: 34,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            color: const Color(0xFF1B1B1B),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 2,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          gradient: LinearGradient(
                            colors: [
                              Colors.orange.withValues(alpha: 0.25),
                              Colors.orange.withValues(alpha: 0.08),
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                        ),
                        child: const Icon(
                          Icons.location_on,
                          color: Colors.orange,
                          size: 40,
                        ),
                      ),

                      const SizedBox(width: 16),

                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: 4,
                                  height: 52,
                                  decoration: BoxDecoration(
                                    color: Colors.orange,
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                ),

                                const SizedBox(width: 14),

                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        'Dernière position connue',
                                        style: TextStyle(
                                          fontSize: 20,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),

                                      const SizedBox(height: 2),

                                      Text(
                                        'Latitude : $latitude',
                                        style: const TextStyle(
                                          fontSize: 16,
                                        ),
                                      ),

                                      Text(
                                        'Longitude : $longitude',
                                        style: const TextStyle(
                                          fontSize: 16,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),

                            const SizedBox(height: 18),

                            Align(
                              alignment: Alignment.centerLeft,
                              child: ElevatedButton.icon(
                                onPressed: () async {
                                  final googleMapsUrl =
                                      'https://www.google.com/maps/search/?api=1&query=$latitude,$longitude';

                                  final uri = Uri.parse(googleMapsUrl);

                                  if (await canLaunchUrl(uri)) {
                                    await launchUrl(
                                      uri,
                                      mode: LaunchMode.externalApplication,
                                    );
                                  }
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF2B2035),
                                  foregroundColor: const Color(0xFFD7B8FF),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 18,
                                    vertical: 14,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(30),
                                  ),
                                ),
                                icon: const Icon(Icons.map),
                                label: const Text(
                                  'Ouvrir dans Google Maps',
                                ),
                              ),
                            ),

                            const SizedBox(height: 14),

                            Row(
                              children: [
                                const Icon(
                                  Icons.access_time,
                                  color: Colors.white54,
                                  size: 16,
                                ),

                                const SizedBox(width: 8),

                                Expanded(
                                  child: Text(
                                    lastUpdate == null
                                        ? 'Dernière mise à jour inconnue'
                                        : 'Dernière mise à jour : ${DateFormat('dd/MM/yyyy HH:mm:ss').format(lastUpdate!.toLocal())}',
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(width: 20),

                Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 26,
                vertical: 22,
              ),
              decoration: BoxDecoration(
                color: const Color(0xFF1F1F1F),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: getStatusColor(),
                  width: 2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: getStatusColor().withValues(alpha: 0.18),
                    blurRadius: 18,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    width: 92,
                    height: 92,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: getStatusColor().withValues(alpha: 0.12),
                      border: Border.all(
                        color: getStatusColor().withValues(alpha: 0.45),
                        width: 2,
                      ),
                    ),
                    child: Icon(
                      getStatusIcon(),
                      color: getStatusColor(),
                      size: 54,
                    ),
                  ),

                  const SizedBox(width: 24),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        Text(
                          'STATUT DU RIDE',
                          style: TextStyle(
                            color: Colors.white.withValues(
                              alpha: 0.65,
                            ),
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1.2,
                          ),
                        ),

                        const SizedBox(height: 6),

                        Text(
                          getStatusLabel(),
                          style: TextStyle(
                            color: getStatusColor(),
                            fontSize: 36,
                            fontWeight: FontWeight.bold,
                          ),
                        ),

                        const SizedBox(height: 14),

                        Container(
                          height: 1,
                          color: Colors.white.withValues(
                            alpha: 0.08,
                          ),
                        ),

                        const SizedBox(height: 14),

                        Row(
                          children: [
                            Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                color: getStatusColor(),
                                shape: BoxShape.circle,
                              ),
                            ),

                            const SizedBox(width: 10),

                            Expanded(
                              child: Text(
                                rideStatus == 'in_progress'
                                    ? 'Le ride est actuellement en cours'
                                    : rideStatus == 'paused'
                                        ? 'Le ride est actuellement en pause'
                                        : rideStatus == 'finished'
                                            ? 'Le ride est terminé'
                                            : 'Statut indisponible',
                                style: TextStyle(
                                  color: Colors.white.withValues(
                                    alpha: 0.78,
                                  ),
                                  fontSize: 15,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

              ],
            ),
          ),

          const SizedBox(height: 8),

          Text(
            appVersion,
            style: const TextStyle(
              fontSize: 12,
              color: Colors.white38,
            ),
          ),
        ],
      ),
    );
  }
}