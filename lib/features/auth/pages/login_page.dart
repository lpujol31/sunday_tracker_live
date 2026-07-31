import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../core/auth/auth_service.dart';
import '../../../core/theme/admin_theme.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = false;
  bool _obscure = true;
  String? _error;

  Future<void> _signIn() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (email.isEmpty) { setState(() => _error = 'Entre ton adresse email.'); return; }
    if (password.isEmpty) { setState(() => _error = 'Entre ton mot de passe.'); return; }
    setState(() { _loading = true; _error = null; });
    try {
      await AuthService.signIn(email, password);
      if (mounted) context.go('/admin');
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AdminColors.bg,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Container(width: 8, height: 8, decoration: const BoxDecoration(color: AdminColors.accent, shape: BoxShape.circle)),
                  const SizedBox(width: 8),
                  const Text('SUNDAY TRACKER', style: TextStyle(color: AdminColors.textSecondary, fontSize: 10, letterSpacing: 2, fontWeight: FontWeight.w600)),
                ]),
                const SizedBox(height: 40),
                const Text('Admin', style: TextStyle(color: AdminColors.textPrimary, fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: -1)),
                const SizedBox(height: 6),
                const Text('Connecte-toi avec ton email et ton mot de passe.', style: TextStyle(color: AdminColors.textSecondary, fontSize: 14, height: 1.5)),
                const SizedBox(height: 32),
                TextField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.username],
                  autofocus: true,
                  textInputAction: TextInputAction.next,
                  style: const TextStyle(color: AdminColors.textPrimary, fontSize: 14),
                  decoration: const InputDecoration(hintText: 'toi@example.com', prefixIcon: Icon(Icons.mail_outline, color: AdminColors.textSecondary, size: 18)),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _passwordController,
                  obscureText: _obscure,
                  autofillHints: const [AutofillHints.password],
                  onSubmitted: (_) => _signIn(),
                  style: const TextStyle(color: AdminColors.textPrimary, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Mot de passe',
                    prefixIcon: const Icon(Icons.lock_outline, color: AdminColors.textSecondary, size: 18),
                    suffixIcon: IconButton(
                      icon: Icon(_obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined, color: AdminColors.textSecondary, size: 18),
                      onPressed: () => setState(() => _obscure = !_obscure),
                      tooltip: _obscure ? 'Afficher' : 'Masquer',
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(color: AdminColors.dangerDim, borderRadius: BorderRadius.circular(8), border: Border.all(color: AdminColors.danger, width: 0.5)),
                    child: Row(children: [
                      const Icon(Icons.error_outline, color: AdminColors.danger, size: 16),
                      const SizedBox(width: 8),
                      Expanded(child: Text(_error!, style: const TextStyle(color: AdminColors.danger, fontSize: 13))),
                    ]),
                  ),
                ],
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _loading ? null : _signIn,
                    child: _loading
                        ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: AdminColors.bg))
                        : const Text('Se connecter'),
                  ),
                ),
                const SizedBox(height: 32),
                const Divider(color: AdminColors.border),
                const SizedBox(height: 16),
                const Text('Accès réservé à l\'administrateur.', style: TextStyle(color: AdminColors.textSecondary, fontSize: 11)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
