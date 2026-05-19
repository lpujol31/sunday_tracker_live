import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

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

  final shareCode =
      Uri.base.queryParameters['code'];

  @override
  void initState() {
    super.initState();

    loadLastPosition();
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
          .select('id')
          .eq('share_code', shareCode!)
          .single();

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

    if (errorMessage != null ||
        latitude == null ||
        longitude == null) {

      return Scaffold(
        backgroundColor:
            const Color(0xFF0D0D0D),

        body: Center(
          child: Text(
            errorMessage ??
                'Aucune position disponible',
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
          'Sunday Tracker',
        ),
      ),

      body: Column(
        children: [

          Expanded(
            child: FlutterMap(

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

            padding:
                const EdgeInsets.all(20),

            color:
                const Color(0xFF1B1B1B),

            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,

              children: [

                const Text(
                  'Dernière position connue',

                  style: TextStyle(
                    fontSize: 20,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),

                const SizedBox(
                  height: 8,
                ),

                Text(
                  'Latitude : $latitude',
                ),

                Text(
                  'Longitude : $longitude',
                ),

                const SizedBox(
                  height: 8,
                ),

                Text(

                  lastUpdate == null
                      ? 'Dernière mise à jour inconnue'

                      : 'Dernière mise à jour : ${lastUpdate!.toLocal()}',

                  style: const TextStyle(
                    color: Colors.white70,
                  ),
                ),

                const SizedBox(
                  height: 16,
                ),

                SizedBox(

                  width: double.infinity,

                  child:
                      ElevatedButton.icon(

                    onPressed: () async {

                      final googleMapsUrl =
                          'https://www.google.com/maps/search/?api=1&query=$latitude,$longitude';

                      final uri = Uri.parse(
                        googleMapsUrl,
                      );

                      if (await canLaunchUrl(
                        uri,
                      )) {

                        await launchUrl(
                          uri,

                          mode:
                              LaunchMode.externalApplication,
                        );
                      }
                    },

                    icon: const Icon(
                      Icons.map,
                    ),

                    label: const Text(
                      'Ouvrir dans Google Maps',
                    ),
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