// VERSION DEBUG — remplace temporairement main.dart pour identifier le crash
// Une fois le bug trouvé, on remet le vrai main.dart
import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';

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

String _step = 'démarrage';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  runApp(const _DebugApp()); // affiche l'UI immédiatement

  try {
    _step = 'usePathUrlStrategy';
    usePathUrlStrategy();

    _step = 'Supabase.initialize';
    await Supabase.initialize(url: _supabaseUrl, anonKey: _supabaseAnonKey);

    _step = 'Firebase.initializeApp';
    await Firebase.initializeApp(options: _firebaseOptions);

    _step = 'FirebaseAuth.isSignInWithEmailLink';
    final currentUrl = Uri.base.toString();
    FirebaseAuth.instance.isSignInWithEmailLink(currentUrl);

    _step = 'terminé sans erreur ✅';
  } catch (e) {
    _step = 'ERREUR à l\'étape "$_step" : $e';
  }
}

class _DebugApp extends StatefulWidget {
  const _DebugApp();
  @override
  State<_DebugApp> createState() => _DebugAppState();
}

class _DebugAppState extends State<_DebugApp> {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        backgroundColor: const Color(0xFF0F1117),
        body: Center(
          child: StreamBuilder(
            stream: Stream.periodic(const Duration(milliseconds: 200)),
            builder: (context, _) => Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                'Étape : $_step',
                style: const TextStyle(color: Colors.white, fontSize: 14, fontFamily: 'monospace'),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
