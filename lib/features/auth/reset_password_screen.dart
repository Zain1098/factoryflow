import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_providers.dart';

/// 2-step password reset:
/// Step 1 — Enter the numeric verification code from email.
/// Step 2 — Enter + confirm new password
class ResetPasswordScreen extends ConsumerStatefulWidget {
  const ResetPasswordScreen({super.key, required this.email});
  final String email;

  @override
  ConsumerState<ResetPasswordScreen> createState() =>
      _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends ConsumerState<ResetPasswordScreen> {
  // Step 1
  final _otpCtrl = TextEditingController();
  // Step 2
  final _passCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();

  int _step = 1; // 1 = OTP, 2 = new password
  bool _obscure = true;
  bool _loading = false;
  bool _resending = false;
  int _resendCooldown = 60;
  Timer? _resendTimer;
  String? _error;

  @override
  void initState() {
    super.initState();
    _startResendCooldown();
  }

  @override
  void dispose() {
    _resendTimer?.cancel();
    _otpCtrl.dispose();
    _passCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  void _startResendCooldown() {
    _resendTimer?.cancel();
    if (mounted) setState(() => _resendCooldown = 60);
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      if (_resendCooldown <= 1) {
        timer.cancel();
        setState(() => _resendCooldown = 0);
      } else {
        setState(() => _resendCooldown--);
      }
    });
  }

  Future<void> _verifyOtp() async {
    final otp = _otpCtrl.text.trim();
    if (!RegExp(r'^\d{6,10}$').hasMatch(otp)) {
      setState(() => _error = 'Enter the 6 to 10 digit code from your email.');
      return;
    }
    // Verify with Supabase before allowing a password change.
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(authRepositoryProvider).verifyPasswordResetOtp(
            email: widget.email,
            token: otp,
          );
      if (!mounted) return;
      setState(() {
        _step = 2;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _friendlyRecoveryError(error);
      });
    }
  }

  Future<void> _resendOtp() async {
    if (_resendCooldown > 0) return;
    setState(() => _resending = true);
    try {
      await ref.read(authRepositoryProvider).sendPasswordResetOtp(widget.email);
      if (mounted) {
        _otpCtrl.clear();
        _startResendCooldown();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('A new code was sent to your email.')),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = _friendlyRecoveryError(e));
    } finally {
      if (mounted) setState(() => _resending = false);
    }
  }

  Future<void> _submitNewPassword() async {
    final pass = _passCtrl.text;
    if (pass.length < 8) {
      setState(() => _error = 'Password must be at least 8 characters.');
      return;
    }
    if (pass != _confirmCtrl.text) {
      setState(() => _error = 'Passwords do not match.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(authRepositoryProvider).completePasswordReset(pass);
      if (!mounted) return;
      Navigator.of(context).pop(true); // true = success
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = _friendlyRecoveryError(e);
        });
      }
    }
  }

  String _friendlyRecoveryError(Object error) {
    final message = error.toString().toLowerCase();
    if (message.contains('otp_expired') ||
        message.contains('token has expired') ||
        message.contains('invalid or expired')) {
      return 'This code has expired or was already used. Tap Resend Code and enter the newest code.';
    }
    if (message.contains('recovery session')) {
      return 'Your recovery session expired. Tap Resend Code and verify it again.';
    }
    if (message.contains('same_password')) {
      return 'Your new password must be different from the previous password.';
    }
    if (message.contains('rate') || message.contains('429')) {
      return 'Too many requests. Please wait a few minutes before trying again.';
    }
    if (message.contains('password')) {
      return 'Password could not be updated. Use at least 8 characters and request a new code if needed.';
    }
    return 'Unable to reset password. Please try again or request a new code.';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        title: Text(_step == 1 ? 'Forgot password' : 'Reset password'),
        leading: _step == 2
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() {
                  _step = 1;
                  _error = null;
                }),
              )
            : null,
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: isDark
                ? [
                    theme.colorScheme.surface,
                    theme.colorScheme.primary.withValues(alpha: 0.32),
                    theme.colorScheme.surface,
                  ]
                : [
                    theme.colorScheme.primary.withValues(alpha: 0.14),
                    theme.colorScheme.surface,
                    theme.colorScheme.primaryContainer.withValues(alpha: 0.6),
                  ],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 72, 20, 24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  children: [
                    _buildBrandHeader(theme),
                    const SizedBox(height: 24),
                    _buildStepIndicator(theme),
                    const SizedBox(height: 28),
                    _buildCard(theme, isDark),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBrandHeader(ThemeData theme) {
    return Column(
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: LinearGradient(
              colors: [
                theme.colorScheme.primary,
                theme.colorScheme.secondary,
              ],
            ),
            boxShadow: [
              BoxShadow(
                color: theme.colorScheme.primary.withValues(alpha: 0.30),
                blurRadius: 16,
                offset: const Offset(0, 7),
              ),
            ],
          ),
          child: const Icon(Icons.factory_rounded, color: Colors.white),
        ),
        const SizedBox(height: 12),
        Text(
          'FactoryFlow',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }

  Widget _buildStepIndicator(ThemeData theme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _StepDot(
          number: 1,
          label: 'Verify Code',
          active: _step == 1,
          done: _step > 1,
          theme: theme,
        ),
        _StepLine(done: _step > 1, theme: theme),
        _StepDot(
          number: 2,
          label: 'New Password',
          active: _step == 2,
          done: false,
          theme: theme,
        ),
      ],
    );
  }

  Widget _buildCard(ThemeData theme, bool isDark) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.05, 0),
            end: Offset.zero,
          ).animate(anim),
          child: child,
        ),
      ),
      child: _step == 1
          ? _buildOtpStep(theme, isDark, key: const ValueKey(1))
          : _buildPasswordStep(theme, isDark, key: const ValueKey(2)),
    );
  }

  Widget _buildOtpStep(ThemeData theme, bool isDark, {Key? key}) {
    return Container(
      key: key,
      padding: const EdgeInsets.all(24),
      decoration: _cardDecoration(theme, isDark),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildIcon(theme, Icons.mark_email_read_outlined),
          const SizedBox(height: 20),
          Text(
            'Check your inbox',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            'We sent a verification code to\n${widget.email}',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 28),
          TextField(
            controller: _otpCtrl,
            autofocus: true,
            enabled: !_loading,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            maxLength: 10,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onSubmitted: (_) => _verifyOtp(),
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 10,
            ),
            decoration: const InputDecoration(
              labelText: 'Verification code (6–10 digits)',
              hintText: '0000000000',
              counterText: '',
              prefixIcon: Icon(Icons.password_outlined),
            ),
          ),
          if (_error != null) _buildError(theme),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _loading ? null : _verifyOtp,
            icon: const Icon(Icons.arrow_forward_rounded, size: 18),
            label: const Text('Continue'),
            style: FilledButton.styleFrom(
              minimumSize: const Size(double.infinity, 50),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          const SizedBox(height: 4),
          TextButton(
            onPressed: _resending || _loading || _resendCooldown > 0
                ? null
                : _resendOtp,
            child: Text(
              _resending
                  ? 'Sending...'
                  : _resendCooldown > 0
                      ? 'Resend code in ${_resendCooldown}s'
                      : 'Resend code',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPasswordStep(ThemeData theme, bool isDark, {Key? key}) {
    return Container(
      key: key,
      padding: const EdgeInsets.all(24),
      decoration: _cardDecoration(theme, isDark),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildIcon(theme, Icons.lock_reset_outlined),
          const SizedBox(height: 20),
          Text(
            'Create new password',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            'Choose a strong password with at least 8 characters.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 28),
          TextField(
            controller: _passCtrl,
            obscureText: _obscure,
            enabled: !_loading,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'New password',
              prefixIcon: const Icon(Icons.lock_outline),
              suffixIcon: IconButton(
                icon: Icon(
                  _obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _confirmCtrl,
            obscureText: _obscure,
            enabled: !_loading,
            onSubmitted: (_) => _submitNewPassword(),
            decoration: const InputDecoration(
              labelText: 'Confirm new password',
              prefixIcon: Icon(Icons.verified_user_outlined),
            ),
          ),
          if (_error != null) _buildError(theme),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _loading ? null : _submitNewPassword,
            icon: _loading
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check_circle_outline, size: 18),
            label: Text(_loading ? 'Updating...' : 'Update password'),
            style: FilledButton.styleFrom(
              minimumSize: const Size(double.infinity, 50),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIcon(ThemeData theme, IconData icon) {
    return Center(
      child: CircleAvatar(
        radius: 34,
        backgroundColor: theme.colorScheme.primaryContainer,
        child:
            Icon(icon, size: 34, color: theme.colorScheme.onPrimaryContainer),
      ),
    );
  }

  Widget _buildError(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(
              Icons.error_outline,
              color: theme.colorScheme.onErrorContainer,
              size: 18,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }

  BoxDecoration _cardDecoration(ThemeData theme, bool isDark) {
    return BoxDecoration(
      color: theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(28),
      border: Border.all(
        color: isDark
            ? Colors.white.withValues(alpha: 0.08)
            : theme.colorScheme.primary.withValues(alpha: 0.14),
      ),
      boxShadow: [
        BoxShadow(
          color: isDark
              ? Colors.black.withValues(alpha: 0.3)
              : theme.colorScheme.primary.withValues(alpha: 0.10),
          blurRadius: 24,
          offset: const Offset(0, 8),
        ),
      ],
    );
  }
}

// ── Step indicator widgets ────────────────────────────────────────────────────

class _StepDot extends StatelessWidget {
  const _StepDot({
    required this.number,
    required this.label,
    required this.active,
    required this.done,
    required this.theme,
  });
  final int number;
  final String label;
  final bool active;
  final bool done;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final color = (active || done)
        ? theme.colorScheme.primary
        : theme.colorScheme.outline;
    return Column(
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: (active || done)
                ? theme.colorScheme.primary
                : theme.colorScheme.surfaceContainerHighest,
            border: Border.all(color: color, width: 2),
          ),
          child: Center(
            child: done
                ? Icon(
                    Icons.check,
                    size: 18,
                    color: theme.colorScheme.onPrimary,
                  )
                : Text(
                    '$number',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: active
                          ? theme.colorScheme.onPrimary
                          : theme.colorScheme.outline,
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: color,
            fontWeight: active ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ],
    );
  }
}

class _StepLine extends StatelessWidget {
  const _StepLine({required this.done, required this.theme});
  final bool done;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        width: 60,
        height: 2,
        margin: const EdgeInsets.symmetric(horizontal: 8),
        color: done
            ? theme.colorScheme.primary
            : theme.colorScheme.outline.withValues(alpha: 0.3),
      ),
    );
  }
}
