import 'package:flutter/material.dart';
import '../../../../core/theme/admin_theme.dart';

class _PlaceholderSection extends StatelessWidget {
  final IconData icon; final String title; final String description;
  const _PlaceholderSection({required this.icon, required this.title, required this.description});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(title, style: const TextStyle(color: AdminColors.textPrimary, fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: -0.5)),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: AdminColors.surface, borderRadius: BorderRadius.circular(4), border: Border.all(color: AdminColors.border)),
            child: const Text('À VENIR', style: TextStyle(color: AdminColors.textSecondary, fontSize: 10, letterSpacing: 0.8)),
          ),
        ]),
        const SizedBox(height: 4),
        Text(description, style: const TextStyle(color: AdminColors.textSecondary, fontSize: 14, height: 1.5)),
        const SizedBox(height: 48),
        Center(child: Column(children: [
          Container(width: 64, height: 64, decoration: BoxDecoration(color: AdminColors.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: AdminColors.border)), child: Icon(icon, color: AdminColors.border, size: 30)),
          const SizedBox(height: 16),
          const Text('À venir', style: TextStyle(color: AdminColors.textSecondary, fontSize: 13)),
        ])),
      ]),
    );
  }
}

class UsersSection extends StatelessWidget {
  const UsersSection({super.key});
  @override
  Widget build(BuildContext context) => const _PlaceholderSection(icon: Icons.people_outline, title: 'Utilisateurs', description: 'Gestion des comptes, rôles et accès.');
}

class JobsSection extends StatelessWidget {
  const JobsSection({super.key});
  @override
  Widget build(BuildContext context) => const _PlaceholderSection(icon: Icons.terminal_outlined, title: 'Jobs', description: 'Déclenchement et suivi des scripts en arrière-plan.');
}

class LogsSection extends StatelessWidget {
  const LogsSection({super.key});
  @override
  Widget build(BuildContext context) => const _PlaceholderSection(icon: Icons.receipt_long_outlined, title: 'Logs', description: 'Audit trail paginé, filtrable et exportable.');
}
