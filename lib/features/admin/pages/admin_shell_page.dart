import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/auth/auth_service.dart';
import '../../../core/theme/admin_theme.dart';
import '../widgets/admin_sidebar.dart';
import 'sections/cleanup_section.dart';
import 'sections/placeholder_sections.dart';

class AdminShellPage extends StatefulWidget {
  final String initialSection;
  const AdminShellPage({super.key, this.initialSection = 'cleanup'});
  @override
  State<AdminShellPage> createState() => _AdminShellPageState();
}

class _AdminShellPageState extends State<AdminShellPage> {
  late String _activeSection;

  @override
  void initState() {
    super.initState();
    _activeSection = widget.initialSection;
  }

  Widget _buildContent() => switch (_activeSection) {
    'cleanup' => const CleanupSection(),
    'users'   => const UsersSection(),
    'jobs'    => const JobsSection(),
    'logs'    => const LogsSection(),
    _         => const CleanupSection(),
  };

  @override
  Widget build(BuildContext context) {
    // La session Supabase est déjà résolue après Supabase.initialize() dans
    // main() (le magic link est capté au chargement). Le stream ne sert qu'à
    // rebuild sur connexion/déconnexion.
    return StreamBuilder<AuthState>(
      stream: AuthService.authStateChanges,
      builder: (context, snapshot) {
        // Non connecté (ou email non autorisé) → page de login.
        if (!AuthService.isAuthenticated || !AuthService.isAuthorized) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) context.go('/admin/login');
          });
          return const Scaffold(backgroundColor: AdminColors.bg);
        }
        // Connecté & autorisé → interface
        final isNarrow = MediaQuery.of(context).size.width < 768;
        if (isNarrow) {
          return Scaffold(
            backgroundColor: AdminColors.bg,
            appBar: AppBar(
              backgroundColor: AdminColors.surface, elevation: 0,
              title: const Text('Admin', style: TextStyle(color: AdminColors.textPrimary, fontSize: 16)),
              iconTheme: const IconThemeData(color: AdminColors.textSecondary),
              bottom: PreferredSize(preferredSize: const Size.fromHeight(1), child: Container(height: 1, color: AdminColors.border)),
            ),
            drawer: Drawer(backgroundColor: AdminColors.surface, child: AdminSidebar(activeSection: _activeSection, onSectionChanged: (s) { setState(() => _activeSection = s); Navigator.of(context).pop(); })),
            body: _buildContent(),
          );
        }
        return Scaffold(
          backgroundColor: AdminColors.bg,
          body: Row(children: [
            AdminSidebar(activeSection: _activeSection, onSectionChanged: (s) => setState(() => _activeSection = s)),
            Expanded(child: _buildContent()),
          ]),
        );
      },
    );
  }
}
