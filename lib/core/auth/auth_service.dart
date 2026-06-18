import 'package:firebase_auth/firebase_auth.dart';
import 'dart:html' as html;

class AuthService {
  static final _auth = FirebaseAuth.instance;

  static const List<String> _authorizedEmails = [
    'lpujol31@icloud.com',
    'lpujol.novadys@gmail.com',
  ];

  static const _emailKey = 'adminPendingEmail';

  static String get _returnUrl {
    final host = Uri.base.host;
    final isLocal = host == 'localhost' || host == '127.0.0.1';
    if (isLocal) {
      return '${Uri.base.scheme}://${Uri.base.host}:${Uri.base.port}/admin';
    }
    return 'https://sunday-tracker-live.web.app/admin';
  }

  static User? get currentUser => _auth.currentUser;
  static Stream<User?> get authStateChanges => _auth.authStateChanges();
  static bool get isAuthenticated => _auth.currentUser != null;

  static Future<void> sendMagicLink(String email) async {
    final normalizedEmail = email.trim().toLowerCase();

    if (!_authorizedEmails
        .map((e) => e.toLowerCase())
        .contains(normalizedEmail)) {
      throw Exception('Accès non autorisé.');
    }

    await _auth.sendSignInLinkToEmail(
      email: email.trim(),
      actionCodeSettings: ActionCodeSettings(
        url: _returnUrl,
        handleCodeInApp: true,
        iOSBundleId: 'com.yourcompany.sundayTrackerLive',
        androidPackageName: 'com.yourcompany.sunday_tracker_live',
        androidInstallApp: false,
      ),
    );

    html.window.localStorage[_emailKey] = email.trim();
  }

  static Future<bool> handleMagicLinkIfPresent(String link) async {
  if (!_auth.isSignInWithEmailLink(link)) return false;

  final email = html.window.localStorage[_emailKey];
  if (email == null || email.isEmpty) return false;

  // Debug : vérifier le lien reçu
  print('Magic link reçu : $link');
  print('Email récupéré : $email');

  await _auth.signInWithEmailLink(
    email: email,
    emailLink: link,
  );

  html.window.localStorage.remove(_emailKey);
  return true;
}

  static Future<void> signOut() async => _auth.signOut();
}