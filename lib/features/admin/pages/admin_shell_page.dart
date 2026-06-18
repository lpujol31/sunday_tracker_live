import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import '../../../core/theme/admin_theme.dart';
import '../../../main.dart' show firebaseOptions;
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
  Stream<User?>? _authStream;

  @override
  void initState() {
    super.initState();
    _activeSection = widget.initialSection;
    _initAuth();
  }

  Future<void> _initAuth() async {
    try {
      // Firebase déjà initialisé si on arrive via /admin au démarrage
      _authStream = FirebaseAuth.instance.authStateChanges();
    } catch (_) {
      // Cas où on navigue vers /admin depuis / sans recharger la page
      // Firebase n'est pas encore initialisé — on l'init maintenant
      try {
        await Firebase.initializeApp(options: firebaseOptions);
      } catch (_) {} // déjà initialisé
      _authStream = FirebaseAuth.instance.authStateChanges();
    }
    if (mounted) setState(() {});
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
    if (_authStream == null) {
      return const Scaffold(backgroundColor: AdminColors.bg, body: Center(child: CircularProgressIndicator(color: AdminColors.accent)));
    }

    return StreamBuilder<User?>(
      stream: _authStream,
      builder: (context, snapshot) {
        // En attente état Firebase
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(backgroundColor: AdminColors.bg, body: Center(child: CircularProgressIndicator(color: AdminColors.accent)));
        }
        // Non connecté → login
        if (snapshot.data == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) context.go('/admin/login');
          });
          return const Scaffold(backgroundColor: AdminColors.bg);
        }
        // Connecté → interface
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
