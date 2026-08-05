import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/network/sync_service.dart';
import 'auth_providers.dart';
import 'signup_verification_screen.dart';
import 'reset_password_screen.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _workspaceCtrl = TextEditingController();
  bool _obscure = true;
  bool _isResetting = false;
  bool _isSignUp = false;
  late final AnimationController _anim;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  bool _hasLocalSession = false;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fade = CurvedAnimation(parent: _anim, curve: Curves.easeOut);
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.06),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _anim, curve: Curves.easeOut));
    _anim.forward();
    _checkLocalSession();
  }

  Future<void> _checkLocalSession() async {
    final user = await ref.read(authRepositoryProvider).getLocalSession();
    if (mounted) setState(() => _hasLocalSession = user != null);
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _nameCtrl.dispose();
    _workspaceCtrl.dispose();
    _anim.dispose();
    super.dispose();
  }

  // ── Actions ────────────────────────────────────────────────────────────

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_isSignUp) {
      final verificationRequired =
          await ref.read(currentUserProvider.notifier).signUp(
                email: _emailCtrl.text.trim(),
                password: _passwordCtrl.text,
                profileName: _nameCtrl.text.trim(),
                workspaceName: _workspaceCtrl.text.trim(),
              );
      if (!mounted) return;
      final signUpState = ref.read(currentUserProvider);
      if (verificationRequired && !signUpState.hasError) {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => SignupVerificationScreen(
              email: _emailCtrl.text.trim(),
              profileName: _nameCtrl.text.trim(),
              workspaceName: _workspaceCtrl.text.trim(),
            ),
          ),
        );
        return;
      }
    } else {
      await ref.read(currentUserProvider.notifier).signIn(
            _emailCtrl.text.trim(),
            _passwordCtrl.text,
          );
    }
    if (!mounted) return;
    final s = ref.read(currentUserProvider);
    if (s.hasError) _showError(_friendlyError(s.error));
    if (!s.hasError && s.value == null && !s.isLoading) {
      _showError('No user profile found. Contact your administrator.');
    }
  }

  Future<void> _signInWithGoogle() async {
    await ref.read(currentUserProvider.notifier).signInWithGoogle();
    if (!mounted) return;
    final s = ref.read(currentUserProvider);
    if (s.hasError) _showError(_friendlyError(s.error));
  }

  Future<void> _continueOffline() async {
    await ref.read(currentUserProvider.notifier).continueOffline();
  }

  Future<void> _forgotPassword() async {
    final email = _emailCtrl.text.trim();
    if (email.isEmpty || !_validEmail(email)) {
      _showError('Enter a valid email first, then tap Forgot Password.');
      return;
    }
    setState(() => _isResetting = true);
    try {
      await ref.read(authRepositoryProvider).sendPasswordResetOtp(email);
      if (!mounted) return;
      // Navigate to OTP + new password screen
      final success = await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          builder: (_) => ResetPasswordScreen(email: email),
        ),
      );
      if (mounted && success == true) {
        _showSuccess('Password updated! Please sign in.');
      }
    } catch (e) {
      if (mounted) _showError(_friendlyError(e));
    } finally {
      if (mounted) setState(() => _isResetting = false);
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────

  String _friendlyError(Object? e) {
    final msg = e?.toString() ?? '';
    debugPrint('🔴 AUTH ERROR: $msg'); // always log to terminal
    if (msg.contains('over_email_send_rate_limit') ||
        msg.contains('rate_limit') ||
        msg.contains('Email rate limit') ||
        msg.contains('429')) {
      return 'Email rate limit reached (3 per hour for default SMTP). Please wait a few minutes or check your spam folder.';
    }
    if (msg.contains('Invalid login') || msg.contains('invalid_credentials')) {
      return 'Incorrect email or password.';
    }
    if (msg.contains('Email not confirmed')) {
      return 'Please verify your email before signing in.';
    }
    if (msg.contains('not configured') || msg.contains('Supabase')) {
      return 'Server not configured. Use offline login.';
    }
    if (msg.contains('network') ||
        msg.contains('SocketException') ||
        msg.contains('Failed host lookup')) {
      return 'No internet connection.';
    }
    if (msg.contains('canceled') || msg.contains('cancel')) {
      return 'Google sign-in was canceled.';
    }
    if (msg.contains('already registered') || msg.contains('duplicate')) {
      return 'This email is already registered. Try signing in.';
    }
    if (msg.contains('weak_password') || msg.contains('6 characters')) {
      return 'Password must be at least 6 characters.';
    }
    if (msg.contains('does not exist') ||
        msg.contains('permission denied') ||
        msg.contains('function')) {
      return 'Server setup incomplete — Supabase migrations not applied. Contact developer.';
    }
    // Show actual error in debug, generic for release
    if (kDebugMode) return msg;
    return _isSignUp
        ? 'Sign up failed. Please try again.'
        : 'Sign in failed. Please try again.';
  }

  bool _validEmail(String e) =>
      RegExp(r'^[\w.+\-]+@[a-zA-Z0-9\-]+\.[a-zA-Z0-9\-.]+$').hasMatch(e);

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text(msg)),
          ],
        ),
        backgroundColor: Theme.of(context).colorScheme.error,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  void _showSuccess(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(
              Icons.check_circle_outline,
              color: Colors.white,
              size: 18,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(msg)),
          ],
        ),
        backgroundColor: const Color(0xFF2A9D8F),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final isLoading = ref.watch(currentUserProvider).isLoading;
    final connected = ref.watch(supabaseConnectedProvider);
    final isOnline = ref.watch(isOnlineProvider);
    final showOfflineMode = !isOnline || !connected;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDark
                ? [
                    const Color(0xFF12151A),
                    const Color(0xFF1A2233),
                    const Color(0xFF12151A),
                  ]
                : [
                    const Color(0xFFF0F4FF),
                    const Color(0xFFFFFFFF),
                    const Color(0xFFEEF2FF),
                  ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: FadeTransition(
                opacity: _fade,
                child: SlideTransition(
                  position: _slide,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Column(
                      children: [
                        _buildHeader(theme),
                        const SizedBox(height: 32),

                        if (showOfflineMode) _buildOfflineBanner(theme),
                        if (showOfflineMode) const SizedBox(height: 16),

                        if (_hasLocalSession && showOfflineMode)
                          _buildContinueOfflineCard(theme, isLoading),
                        if (_hasLocalSession && showOfflineMode)
                          const SizedBox(height: 16),

                        _buildCard(
                          theme,
                          isDark,
                          isLoading,
                          connected && isOnline,
                        ),
                        const SizedBox(height: 12),

                        // Divider + Google button
                        if (!_isSignUp) ...[
                          _buildDividerWithText(theme, 'or'),
                          const SizedBox(height: 12),
                          _buildGoogleButton(theme, isLoading),
                        ],
                        const SizedBox(height: 12),

                        // Toggle sign-in / sign-up
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              _isSignUp
                                  ? 'Already have an account? '
                                  : "Don't have an account? ",
                              style: theme.textTheme.bodySmall,
                            ),
                            GestureDetector(
                              onTap: () =>
                                  setState(() => _isSignUp = !_isSignUp),
                              child: Text(
                                _isSignUp ? 'Sign In' : 'Create Account',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: theme.colorScheme.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 24),
                        _buildFooter(theme),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDividerWithText(ThemeData theme, String text) {
    return Row(
      children: [
        Expanded(child: Divider(color: theme.dividerColor)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            text,
            style: TextStyle(
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: 13,
            ),
          ),
        ),
        Expanded(child: Divider(color: theme.dividerColor)),
      ],
    );
  }

  Widget _buildGoogleButton(ThemeData theme, bool isLoading) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: isLoading ? null : _signInWithGoogle,
        icon: Image.network(
          'https://www.gstatic.com/firebasejs/ui/2.0.0/images/auth/google.svg',
          height: 20,
          width: 20,
          errorBuilder: (_, __, ___) =>
              const Icon(Icons.g_mobiledata, size: 24),
        ),
        label: const Text('Continue with Google'),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(double.infinity, 50),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          side: BorderSide(
            color: theme.colorScheme.outline.withValues(alpha: 0.4),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Column(
      children: [
        Container(
          width: 84,
          height: 84,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF3D5A80), Color(0xFF5C7A9E)],
            ),
            borderRadius: BorderRadius.circular(22),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF3D5A80).withValues(alpha: 0.35),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child:
              const Icon(Icons.factory_rounded, size: 42, color: Colors.white),
        ),
        const SizedBox(height: 16),
        Text(
          AppConstants.appName,
          style: theme.textTheme.headlineLarge?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            'Manufacturing ERP',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildOfflineBanner(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.35)),
      ),
      child: const Row(
        children: [
          Icon(Icons.cloud_off_outlined, color: Colors.orange, size: 18),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'No server connection — offline mode available',
              style: TextStyle(
                color: Colors.orange,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContinueOfflineCard(ThemeData theme, bool isLoading) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.green.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Row(
            children: [
              Icon(Icons.offline_bolt_outlined, color: Colors.green, size: 18),
              SizedBox(width: 8),
              Text(
                'Previous session found',
                style: TextStyle(
                  color: Colors.green,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'You can continue working offline. Data will sync when internet is available.',
            style: TextStyle(
              color: Colors.green.withValues(alpha: 0.8),
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: isLoading ? null : _continueOffline,
            icon: const Icon(Icons.play_arrow_rounded, size: 18),
            label: const Text('Continue Offline'),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.green,
              minimumSize: const Size(double.infinity, 46),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCard(
    ThemeData theme,
    bool isDark,
    bool isLoading,
    bool connected,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E2329) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : const Color(0xFF3D5A80).withValues(alpha: 0.1),
        ),
        boxShadow: [
          BoxShadow(
            color: isDark
                ? Colors.black.withValues(alpha: 0.35)
                : const Color(0xFF3D5A80).withValues(alpha: 0.07),
            blurRadius: 28,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      padding: const EdgeInsets.all(24),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _isSignUp
                  ? 'Create Account'
                  : (connected ? 'Sign in' : 'Sign in when online'),
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _isSignUp
                  ? 'Set up your workspace in seconds'
                  : (connected
                      ? 'Enter your credentials to continue'
                      : 'Internet required for first-time login'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),

            // Sign-up only fields
            if (_isSignUp) ...[
              TextFormField(
                controller: _nameCtrl,
                textInputAction: TextInputAction.next,
                enabled: !isLoading,
                decoration: InputDecoration(
                  labelText: 'Your Name',
                  prefixIcon: const Icon(Icons.person_outline),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Name is required' : null,
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _workspaceCtrl,
                textInputAction: TextInputAction.next,
                enabled: !isLoading,
                decoration: InputDecoration(
                  labelText: 'Company / Workspace Name',
                  prefixIcon: const Icon(Icons.business_outlined),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'Workspace name is required'
                    : null,
              ),
              const SizedBox(height: 14),
            ],

            TextFormField(
              controller: _emailCtrl,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              autocorrect: false,
              enabled: !isLoading,
              decoration: InputDecoration(
                labelText: 'Email Address',
                hintText: 'you@example.com',
                prefixIcon: const Icon(Icons.email_outlined),
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
              validator: (v) {
                if (v == null || v.isEmpty) return 'Email is required';
                if (!_validEmail(v.trim())) return 'Enter a valid email';
                return null;
              },
            ),
            const SizedBox(height: 14),

            TextFormField(
              controller: _passwordCtrl,
              obscureText: _obscure,
              textInputAction: TextInputAction.done,
              enabled: !isLoading,
              onFieldSubmitted: (_) => isLoading ? null : _submit(),
              decoration: InputDecoration(
                labelText: 'Password',
                prefixIcon: const Icon(Icons.lock_outlined),
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              validator: (v) {
                if (v == null || v.isEmpty) return 'Password is required';
                if (v.length < 6) return 'Minimum 6 characters';
                return null;
              },
            ),

            if (!_isSignUp)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed:
                      (isLoading || _isResetting) ? null : _forgotPassword,
                  style: TextButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: _isResetting
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(
                          'Forgot Password?',
                          style: TextStyle(
                            fontSize: 13,
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                ),
              ),
            const SizedBox(height: 8),

            FilledButton(
              onPressed: isLoading ? null : _submit,
              style: FilledButton.styleFrom(
                minimumSize: const Size(double.infinity, 50),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: isLoading
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: Colors.white,
                      ),
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          _isSignUp ? 'Create Account' : 'Sign In',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Icon(Icons.arrow_forward_rounded, size: 18),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFooter(ThemeData theme) {
    return Text(
      '© ${DateTime.now().year} FactoryFlow · Secure Manufacturing ERP',
      textAlign: TextAlign.center,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
      ),
    );
  }
}
