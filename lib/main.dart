  import 'package:flutter/material.dart';
  import 'package:flutter_map/flutter_map.dart';
  import 'package:latlong2/latlong.dart';
  import 'package:supabase_flutter/supabase_flutter.dart';
  import 'package:url_launcher/url_launcher.dart';
  import 'package:package_info_plus/package_info_plus.dart';
  import 'package:intl/intl.dart';
  import 'dart:async';
  

  const supabaseUrl = 'https://eltlnrxiuvixjlakjfhz.supabase.co';
  const supabaseAnonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImVsdGxucnhpdXZpeGpsYWtqZmh6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzkyMDIxMTIsImV4cCI6MjA5NDc3ODExMn0.Udyy_6xF09JArDODJNkF-b-idlw4P-52ByzHilOOwwQ';

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

    final shareCode =
        Uri.base.queryParameters['code'];

    String rideStatus = 'unknown';

    @override
    void initState() 
    {
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

    void startAutoRefresh() 
    {
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

    Future<void> loadAppVersion() async 
    {
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
          return Colors.green;

        case 'paused':
          return Colors.orange;

        case 'finished':
          return Colors.blue;

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

    Future<void> loadLastPosition() async {

      if (shareCode == null) {
        setState(() {
          errorMessage =
              'Code de partage manquant.';
          isLoading = false;
        });

        return;
      }

      try {
        final supabase =
            Supabase.instance.client;

        final session = await supabase
            .from('safety_sessions')
            .select('id, status')
            .eq('share_code', shareCode!)
            .single();

        rideStatus = session['status'] ?? 'unknown';

        final position = await supabase
            .from('safety_positions')
            .select()
            .eq(
              'session_id',
              session['id'],
            )
            .order(
              'created_at',
              ascending: false,
            )
            .limit(1)
            .single();

            setState(() {
              latitude = position['latitude'];
              longitude = position['longitude'];

              lastUpdate = DateTime.tryParse(
                position['created_at'],
              );

              isLoading = false;
            });

            WidgetsBinding.instance
                .addPostFrameCallback((_) {

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
    Widget build(BuildContext context) 
    {

      if (isLoading) {
        return const Scaffold(
          body: Center(
            child: CircularProgressIndicator(),
          ),
        );
      }

      if (errorMessage != null ||
          latitude == null ||
          longitude == null) 
      {
        return Scaffold(
            backgroundColor: const Color(0xFF0D0D0D),

            body: SafeArea(
              child: Column(
                children: [
                  const Spacer(),

                  Center(
                    child: Text(
                      errorMessage ??
                          'Aucune position disponible',
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
                        color: Colors.white.withOpacity(0.5),
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

      return Scaffold(

        backgroundColor:
            const Color(0xFF0D0D0D),

        appBar: AppBar(
          backgroundColor:
              const Color(0xFF0D0D0D),

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

                    dropdownColor:
                        const Color(0xFF1B1B1B),

                    iconEnabledColor:
                        Colors.orange,

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

                      changeRefreshInterval(
                        value,
                      );
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
                  initialCenter:
                      currentPosition,

                  initialZoom: 15,
                ),

                children: [

                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',

                    userAgentPackageName:
                        'com.example.sunday_tracker_live',
                  ),

                  MarkerLayer(
                    markers: [

                      Marker(
                        point:
                            currentPosition,

                        width: 80,
                        height: 80,

                        child: const Icon(
                          Icons.location_on,
                          color: Colors.red,
                          size: 42,
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
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Dernière position connue',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),

                        const SizedBox(height: 8),

                        Text('Latitude : $latitude'),
                        Text('Longitude : $longitude'),

                        const SizedBox(height: 8),
                        SizedBox(
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
                            icon: const Icon(Icons.map),
                            label: const Text('Ouvrir dans Google Maps'),
                          ),
                        ),

                        const SizedBox(height: 8),

                        Text(
                          lastUpdate == null
                              ? 'Dernière mise à jour inconnue'
                              : 'Dernière mise à jour : ${lastUpdate!.toLocal()}',
                          style: const TextStyle(
                            color: Colors.white70,
                          ),
                        ),

                      ],
                    ),
                  ),

                  const SizedBox(width: 20),

                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF242424),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: getStatusColor(),
                          width: 2,
                        ),
                      ),
                      child: Column(
                        children: [
                          Icon(
                            getStatusIcon(),
                            color: getStatusColor(),
                            size: 42,
                          ),

                          const SizedBox(height: 10),

                          Text(
                            getStatusLabel(),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: getStatusColor(),
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
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