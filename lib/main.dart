import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:html' as html;
import 'core/router/app_router.dart';
import 'core/theme/admin_theme.dart';
import 'core/auth/auth_service.dart';

const _supabaseUrl = 'https://eltlnrxiuvixjlakjfhz.supabase.co';
const _supabaseAnonKey =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImVsdGxucnhpdXZpeGpsYWtqZmh6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzkyMDIxMTIsImV4cCI6MjA5NDc3ODExMn0.Udyy_6xF09JArDODJNkF-b-idlw4P-52ByzHilOOwwQ';

const _firebaseOptions = FirebaseOptions(
  apiKey: 'AIzaSyCKzrKUwqKvuBowx_yQd4uT7_yc_JUISLg',
  authDomain: 'sunday-tracker-live.firebaseapp.com',
  projectId: 'sunday-tracker-live',
  storageBucket: 'sunday-tracker-live.firebasestorage.app',
  messagingSenderId: '108423848702',
  appId: '1:108423848702:web:0899afcbbb4381e8003baf',
);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  usePathUrlStrategy();

  await Supabase.initialize(url: _supabaseUrl, anonKey: _supabaseAnonKey);
  await Firebase.initializeApp(options: _firebaseOptions);

  final currentUrl = Uri.base.toString();
  final isMagicLink = FirebaseAuth.instance.isSignInWithEmailLink(currentUrl);
  final storedEmail = html.window.localStorage['adminPendingEmail'] ?? '(vide)';

  // Logs visibles dans le terminal Flutter
  debugPrint('=== MAGIC LINK DEBUG ===');
  debugPrint('URL: $currentUrl');
  debugPrint('isMagicLink: $isMagicLink');
  debugPrint('storedEmail: $storedEmail');

  if (isMagicLink) {
    debugPrint('→ Tentative de connexion...');
    try {
      final success = await AuthService.handleMagicLinkIfPresent(currentUrl);
      debugPrint('→ handleMagicLinkIfPresent: $success');
      debugPrint('→ currentUser après: ${FirebaseAuth.instance.currentUser?.email}');
    } catch (e) {
      debugPrint('→ ERREUR: $e');
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
      theme: buildAdminTheme(),
      routerConfig: appRouter,
    );
  }
}