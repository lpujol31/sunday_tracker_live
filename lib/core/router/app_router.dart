// lib/core/router/app_router.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../features/auth/pages/login_page.dart';
import '../../features/auth/pages/link_sent_page.dart';
import '../../features/admin/pages/admin_shell_page.dart';

final appRouter = GoRouter(
  initialLocation: '/admin',
  refreshListenable: _AuthNotifier(),
  redirect: (context, state) {
    final isLoggedIn = FirebaseAuth.instance.currentUser != null;
    final isOnAuthPath = state.matchedLocation.startsWith('/admin/login') ||
        state.matchedLocation.startsWith('/admin/link-sent');

    if (!isLoggedIn && !isOnAuthPath) {
      return '/admin/login';
    }
    if (isLoggedIn && isOnAuthPath) {
      return '/admin';
    }
    return null;
  },
  routes: [
    GoRoute(
      path: '/admin/login',
      builder: (context, state) => const LoginPage(),
    ),
    GoRoute(
      path: '/admin/link-sent',
      builder: (context, state) {
        final email = state.uri.queryParameters['email'] ?? '';
        return LinkSentPage(email: email);
      },
    ),
    GoRoute(
      path: '/admin',
      builder: (context, state) => const AdminShellPage(),
      routes: [
        GoRoute(
          path: ':section',
          builder: (context, state) {
            final section = state.pathParameters['section'] ?? 'cleanup';
            return AdminShellPage(initialSection: section);
          },
        ),
      ],
    ),
    // Route catch-all vers la page live existante
    GoRoute(
      path: '/',
      builder: (context, state) => const Scaffold(
        body: Center(child: Text('Page live')),
      ),
    ),
  ],
  errorBuilder: (context, state) => Scaffold(
    body: Center(child: Text('Page introuvable : ${state.uri}')),
  ),
);

/// Notifie go_router quand l'état Firebase Auth change.
class _AuthNotifier extends ChangeNotifier {
  _AuthNotifier() {
    FirebaseAuth.instance.authStateChanges().listen((_) => notifyListeners());
  }
}
