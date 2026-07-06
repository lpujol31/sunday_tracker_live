import 'package:supabase_flutter/supabase_flutter.dart';

/// Authentification admin via **magic link Supabase**.
///
/// Une seule connexion sert à la fois de porte d'entrée (`/admin`) ET de clé
/// d'accès aux données : la session Supabase porte le `auth.uid()` que la RLS
/// utilise. L'utilisateur doit être présent dans la table `admins` pour que
/// `is_admin()` renvoie true côté serveur (c'est LA vraie protection ; la liste
/// d'emails ci-dessous n'est qu'un garde-fou UX côté client).
class AuthService {
  static SupabaseClient get _client => Supabase.instance.client;

  static const List<String> _authorizedEmails = [
    'lpujol31@icloud.com',
    'lpujol.novadys@gmail.com',
  ];

  static String get _returnUrl {
    final host = Uri.base.host;
    final isLocal = host == 'localhost' || host == '127.0.0.1';
    if (isLocal) {
      return '${Uri.base.scheme}://${Uri.base.host}:${Uri.base.port}/admin';
    }
    return 'https://sunday-tracker-live.web.app/admin';
  }

  static User? get currentUser => _client.auth.currentUser;
  static Session? get currentSession => _client.auth.currentSession;
  static Stream<AuthState> get authStateChanges => _client.auth.onAuthStateChange;
  static bool get isAuthenticated => _client.auth.currentSession != null;

  /// Garde-fou UX : l'email connecté fait-il partie des admins déclarés ?
  /// (La protection réelle des données reste `is_admin()` côté Supabase.)
  static bool get isAuthorized {
    final email = currentUser?.email?.toLowerCase();
    if (email == null) return false;
    return _authorizedEmails.map((e) => e.toLowerCase()).contains(email);
  }

  /// Envoie un magic link Supabase. Au clic dans l'email, l'utilisateur revient
  /// sur `_returnUrl` et supabase_flutter récupère la session automatiquement
  /// (detectSessionInUri, actif par défaut).
  static Future<void> sendMagicLink(String email) async {
    final normalizedEmail = email.trim().toLowerCase();
    if (!_authorizedEmails.map((e) => e.toLowerCase()).contains(normalizedEmail)) {
      throw Exception('Accès non autorisé.');
    }
    await _client.auth.signInWithOtp(
      email: email.trim(),
      emailRedirectTo: _returnUrl,
    );
  }

  static Future<void> signOut() async => _client.auth.signOut();
}
