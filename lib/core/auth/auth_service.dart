import 'package:supabase_flutter/supabase_flutter.dart';

/// Authentification admin via **email + mot de passe Supabase**.
///
/// Volontairement PAS de magic link / OTP : ce flux passerait par le template
/// email « Magic link or OTP », partagé avec la récupération de compte de
/// l'app mobile (même projet Supabase). Le mot de passe supprime ce conflit et
/// évite au passage le piège PKCE (un magic link n'est utilisable que dans le
/// navigateur qui l'a demandé).
///
/// Le compte se crée à la main dans Supabase → Authentication → Users.
///
/// Une seule connexion sert à la fois de porte d'entrée (`/admin`) ET de clé
/// d'accès aux données : la session Supabase porte le `auth.uid()` que la RLS
/// utilise. L'utilisateur doit être présent dans la table `admins` pour que
/// `is_admin()` renvoie true côté serveur (c'est LA vraie protection ; la liste
/// d'emails ci-dessous n'est qu'un garde-fou UX côté client).
class AuthService {
  static SupabaseClient get _client => Supabase.instance.client;

  /// Doit rester aligné sur `public.admins` côté Supabase. Un email admis ici
  /// mais absent de la table franchit le login et atterrit sur un `/admin`
  /// muet : la RLS renvoie des tableaux vides, et l'écran de purge lit ça comme
  /// « base propre » (cf. [isServerAdmin]).
  ///
  /// lpujol31@icloud.com en a été retiré : c'est le compte de l'app mobile, et
  /// `2026-07-10_admin_swap.sql` l'a sorti de `public.admins` — un admin voit
  /// TOUS les rides, ce qu'on ne veut pas dans l'app mobile.
  static const List<String> _authorizedEmails = [
    'lpujol.novadys@gmail.com',
  ];

  static User? get currentUser => _client.auth.currentUser;
  static Session? get currentSession => _client.auth.currentSession;
  static Stream<AuthState> get authStateChanges => _client.auth.onAuthStateChange;
  static bool get isAuthenticated => _client.auth.currentSession != null;

  /// Garde-fou UX : l'email connecté fait-il partie des admins déclarés ?
  /// (La protection réelle des données reste `is_admin()` côté Supabase.)
  static bool get isAuthorized {
    final email = currentUser?.email?.toLowerCase();
    if (email == null) return false;
    return _authorizedEmails.contains(email);
  }

  /// Vérité serveur : `is_admin()` répond-il true pour la session courante ?
  ///
  /// [isAuthorized] ne consulte qu'une liste d'emails compilée dans le bundle ;
  /// un compte peut la satisfaire sans figurer dans `public.admins`. La RLS ne
  /// signale alors rien — ni 403, ni erreur, juste des tableaux vides. À
  /// l'écran cela se lit « base propre » au lieu de « droits manquants », d'où
  /// ce contrôle explicite avant toute analyse.
  static Future<bool> isServerAdmin() async {
    final result = await _client.rpc('is_admin');
    return result == true;
  }

  /// Connexion admin. La session est persistée par supabase_flutter et
  /// rechargée au prochain lancement.
  static Future<void> signIn(String email, String password) async {
    final normalizedEmail = email.trim().toLowerCase();
    if (!_authorizedEmails.contains(normalizedEmail)) {
      throw Exception('Accès non autorisé.');
    }
    try {
      await _client.auth.signInWithPassword(
        email: normalizedEmail,
        password: password,
      );
    } on AuthException catch (e) {
      throw Exception(_translate(e));
    }
  }

  static Future<void> signOut() async => _client.auth.signOut();

  static String _translate(AuthException e) {
    final message = e.message.toLowerCase();
    if (message.contains('invalid login credentials')) {
      return 'Email ou mot de passe incorrect.';
    }
    if (message.contains('email not confirmed')) {
      return 'Email non confirmé côté Supabase.';
    }
    if (message.contains('too many requests') || e.statusCode == '429') {
      return 'Trop de tentatives. Réessaie dans quelques minutes.';
    }
    return 'Connexion impossible. Réessaie.';
  }
}
