import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'auth_providers.dart';

class ForgotPasswordOtpScreen extends ConsumerStatefulWidget {
  const ForgotPasswordOtpScreen({
    super.key,
    required this.email,
  });

  final String email;

  @override
  ConsumerState<ForgotPasswordOtpScreen> createState() =>
      _ForgotPasswordOtpScreenState();
}

class _ForgotPasswordOtpScreenState
    extends ConsumerState<ForgotPasswordOtpScreen> {
  final _otpController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _verifying = false;
  bool _resending = false;
  bool _obscure = true;
  int _cooldownSeconds = 60;
  Timer? _timer;
  String? _error;

  @override
  void initState() {
    super.initState();
    _startCooldownTimer(60);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _otpController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  void _startCooldownTimer(int seconds) {
    setState(() => _cooldownSeconds = seconds);
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      if (_cooldownSeconds > 1) {
        setState(() => _cooldownSeconds--);
      } else {
        setState(() => _cooldownSeconds = 0);
        timer.cancel();
      }
    });
  }

  Future<void> _resetPassword() async {
    final token = _otpController.text.trim();
    final password = _passwordController.text;
    final confirm = _confirmController.text;

    if (!RegExp(r'^\d{6,10}$').hasMatch(token)) {
      setState(
        () => _error = 'Enter the 6 to 10 digit code sent to your email.',
      );
      return;
    }
    if (password.length < 8) {
      setState(() => _error = 'Password must be at least 8 characters long.');
      return;
    }
    if (password != confirm) {
      setState(() => _error = 'Passwords do not match.');
      return;
    }

    setState(() {
      _verifying = true;
      _error = null;
    });

    try {
      await ref.read(authRepositoryProvider).verifyPasswordResetOtp(
            email: widget.email,
            token: token,
          );
      await ref.read(authRepositoryProvider).completePasswordReset(password);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Password reset successfully. Please sign in.'),
        ),
      );
      if (mounted) context.go('/login');
    } catch (e) {
      if (mounted) {
        final errStr = e.toString();
        String userError = 'Password reset failed.';
        if (errStr.contains('same_password')) {
          userError =
              'Your new password must be different from the previous password.';
        } else if (errStr.contains('invalid') ||
            errStr.contains('expired') ||
            errStr.contains('otp')) {
          userError =
              'Invalid or expired OTP code. Please check the code and try again.';
        } else {
          userError = errStr.replaceAll('Exception: ', '');
        }
        setState(() {
          _verifying = false;
          _error = userError;
        });
      }
    }
  }

  Future<void> _resend() async {
    if (_cooldownSeconds > 0) return;
    setState(() {
      _resending = true;
      _error = null;
    });
    try {
      await ref.read(authRepositoryProvider).sendPasswordResetOtp(widget.email);
      if (mounted) {
        _startCooldownTimer(60);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('A new OTP code was sent to your email.'),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        final errStr = error.toString();
        if (errStr.contains('rate_limit') || errStr.contains('429')) {
          _error =
              'Rate limit reached. Please wait a few minutes before resending.';
        } else {
          _error = 'Could not resend OTP: $error';
        }
      }
    } finally {
      if (mounted) setState(() => _resending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Reset Password OTP')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            CircleAvatar(
              radius: 34,
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Icon(
                Icons.lock_reset_outlined,
                size: 34,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Enter OTP & New Password',
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Enter the verification code sent to ${widget.email} and create your new password.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 28),
            TextField(
              controller: _otpController,
              autofocus: true,
              enabled: !_verifying,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              maxLength: 10,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: 8,
              ),
              decoration: const InputDecoration(
                labelText: 'Verification code (6–10 digits)',
                hintText: '0000000000',
                counterText: '',
                prefixIcon: Icon(Icons.password_outlined),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _passwordController,
              obscureText: _obscure,
              enabled: !_verifying,
              decoration: InputDecoration(
                labelText: 'New password (min 8 chars)',
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  onPressed: () => setState(() => _obscure = !_obscure),
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _confirmController,
              obscureText: _obscure,
              enabled: !_verifying,
              onSubmitted: (_) => _resetPassword(),
              decoration: const InputDecoration(
                labelText: 'Confirm new password',
                prefixIcon: Icon(Icons.verified_user_outlined),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color:
                      theme.colorScheme.errorContainer.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _verifying ? null : _resetPassword,
              icon: _verifying
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check_circle_outline),
              label:
                  Text(_verifying ? 'Resetting Password...' : 'Reset Password'),
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: _resending || _verifying || _cooldownSeconds > 0
                  ? null
                  : _resend,
              child: Text(
                _resending
                    ? 'Sending...'
                    : _cooldownSeconds > 0
                        ? 'Resend OTP in ${_cooldownSeconds}s'
                        : 'Resend OTP',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
