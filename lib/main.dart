import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'core/router/app_router.dart';

const _supabaseUrl = 'https://eltlnrxiuvixjlakjfhz.supabase.co';
const _supabaseAnonKey =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImVsdGxucnhpdXZpeGpsYWtqZmh6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzkyMDIxMTIsImV4cCI6MjA5NDc3ODExMn0.Udyy_6xF09JArDODJNkF-b-idlw4P-52ByzHilOOwwQ';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // URLs sans # dans le navigateur
  usePathUrlStrategy();

  // Supabase — page live + admin. `detectSessionInUri` (actif par défaut sur le
  // web) capte automatiquement le magic link admin au retour depuis l'email :
  // plus besoin de handling manuel ici.
  await Supabase.initialize(url: _supabaseUrl, anonKey: _supabaseAnonKey);

  runApp(const SundayTrackerApp());
}

class SundayTrackerApp extends StatelessWidget {
  const SundayTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Sunday Tracker',
      debugShowCheckedModeBanner: false,
      routerConfig: appRouter,
    );
  }
}
