// lib/features/auth/pages/link_sent_page.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/admin_theme.dart';

class LinkSentPage extends StatelessWidget {
  final String email;

  const LinkSentPage({super.key, required this.email});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AdminColors.bg,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Icône animée
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: AdminColors.accentDim,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AdminColors.accent, width: 0.5),
                  ),
                  child: const Icon(
                    Icons.mark_email_read_outlined,
                    color: AdminColors.accent,
                    size: 28,
                  ),
                ),
                const SizedBox(height: 28),
                const Text(
                  'Vérifie ta boîte mail',
                  style: TextStyle(
                    color: AdminColors.textPrimary,
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.8,
                  ),
                ),
                const SizedBox(height: 12),
                RichText(
                  text: TextSpan(
                    style: const TextStyle(
                      color: AdminColors.textSecondary,
                      fontSize: 14,
                      height: 1.6,
                    ),
                    children: [
                      const TextSpan(text: 'Un lien de connexion a été envoyé à\n'),
                      TextSpan(
                        text: email,
                        style: const TextStyle(
                          color: AdminColors.accent,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const TextSpan(
                        text:
                            '\n\nClique sur le lien depuis ce même navigateur — il expirera dans 10 minutes.',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 40),
                const Divider(color: AdminColors.border),
                const SizedBox(height: 20),

                // Retour login
                GestureDetector(
                  onTap: () => context.go('/admin/login'),
                  child: const Text(
                    '← Renvoyer un lien',
                    style: TextStyle(
                      color: AdminColors.textSecondary,
                      fontSize: 13,
                      decoration: TextDecoration.underline,
                      decorationColor: AdminColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
