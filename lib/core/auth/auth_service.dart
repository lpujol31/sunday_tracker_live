// lib/core/auth/auth_service.dart
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:html' as html; // localStorage web

class AuthService {
  static final _auth = FirebaseAuth.instance;

  static const String _adminEmail = 'lpujol31@icloud.com';
  static const String _emailStorageKey = 'adminPendingEmail';

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
    if (email.trim().toLowerCase() != _adminEmail.toLowerCase()) {
      throw Exception('Accès non autorisé.');
    }

    final actionCodeSettings = ActionCodeSettings(
      url: _returnUrl,
      handleCodeInApp: true,
      iOSBundleId: 'com.yourcompany.sundayTrackerLive',
      androidPackageName: 'com.yourcompany.sunday_tracker_live',
      androidInstallApp: false,
    );

    await _auth.sendSignInLinkToEmail(
      email: email.trim(),
      actionCodeSettings: actionCodeSettings,
    );

    // Stocke l'email dans localStorage — survit au rechargement de page
    html.window.localStorage[_emailStorageKey] = email.trim();
  }

  static Future<bool> handleMagicLinkIfPresent(String link) async {
    if (!_auth.isSignInWithEmailLink(link)) return false;

    // Récupère l'email depuis localStorage
    final email = html.window.localStorage[_emailStorageKey];
    if (email == null || email.isEmpty) return false;

    await _auth.signInWithEmailLink(email: email, emailLink: link);

    // Nettoie le localStorage après connexion réussie
    html.window.localStorage.remove(_emailStorageKey);
    return true;
  }

  static Future<void> signOut() async {
    await _auth.signOut();
  }
}