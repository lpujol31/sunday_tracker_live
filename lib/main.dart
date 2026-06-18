import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:html' as html;
import 'core/router/app_router.dart';
import 'core/auth/auth_service.dart';

const _supabaseUrl = 'https://eltlnrxiuvixjlakjfhz.supabase.co';
const _supabaseAnonKey =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImVsdGxucnhpdXZpeGpsYWtqZmh6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzkyMDIxMTIsImV4cCI6MjA5NDc3ODExMn0.Udyy_6xF09JArDODJNkF-b-idlw4P-52ByzHilOOwwQ';

const firebaseOptions = FirebaseOptions(
  apiKey: 'AIzaSyCKzrKUwqKvuBowx_yQd4uT7_yc_JUISLg',
  authDomain: 'sunday-tracker-live.firebaseapp.com',
  projectId: 'sunday-tracker-live',
  storageBucket: 'sunday-tracker-live.firebasestorage.app',
  messagingSenderId: '108423848702',
  appId: '1:108423848702:web:0899afcbbb4381e8003baf',
);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // URLs sans # dans le navigateur
  usePathUrlStrategy();

  // Supabase — toujours initialisé (page live + admin)
  await Supabase.initialize(url: _supabaseUrl, anonKey: _supabaseAnonKey);

  // Firebase — uniquement sur les routes /admin
  // Sur la page live (/ ou /?code=...) Firebase ne démarre pas
  final path = Uri.base.path;
  final isAdminRoute = path == '/admin' || path.startsWith('/admin/');

  if (isAdminRoute) {
    await Firebase.initializeApp(options: firebaseOptions);

    // Intercepte le Magic Link au retour depuis l'email
    final currentUrl = Uri.base.toString();
    if (FirebaseAuth.instance.isSignInWithEmailLink(currentUrl)) {
      try {
        await AuthService.handleMagicLinkIfPresent(currentUrl);
      } catch (e) {
        debugPrint('Erreur Magic Link: $e');
      }
    }
  }

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
