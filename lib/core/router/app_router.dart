import 'package:go_router/go_router.dart';
import '../../features/live/live_page.dart';
import '../../features/auth/pages/login_page.dart';
import '../../features/auth/pages/link_sent_page.dart';
import '../../features/admin/pages/admin_shell_page.dart';

final appRouter = GoRouter(
  // Démarre sur l'URL réelle — pas de redirect global, pas de refreshListenable
  initialLocation: Uri.base.path.startsWith('/admin') ? Uri.base.path : '/',
  routes: [
    // Page live — publique, jamais de redirect
    GoRoute(
      path: '/',
      builder: (context, state) => const LivePage(),
    ),

    // Auth admin
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

    // Admin — le guard est dans AdminShellPage via StreamBuilder
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
  ],
);
