import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_providers.dart';

class SignupVerificationScreen extends ConsumerStatefulWidget {
  const SignupVerificationScreen({
    super.key,
    required this.email,
    required this.profileName,
    required this.workspaceName,
    required this.joinCode,
  });

  final String email;
  final String profileName;
  final String workspaceName;
  final String joinCode;

  @override
  ConsumerState<SignupVerificationScreen> createState() =>
      _SignupVerificationScreenState();
}

class _SignupVerificationScreenState
    extends ConsumerState<SignupVerificationScreen> {
  final _otpController = TextEditingController();
  bool _verifying = false;
  bool _resending = false;
  int _cooldownSeconds = 0;
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

  Future<void> _verify() async {
    final token = _otpController.text.trim();
    if (!RegExp(r'^\d{6,10}$').hasMatch(token)) {
      setState(
        () => _error = 'Enter the 6 to 10 digit code sent to your email.',
      );
      return;
    }
    setState(() {
      _verifying = true;
      _error = null;
    });
    await ref.read(currentUserProvider.notifier).verifySignUpOtp(
          email: widget.email,
          token: token,
          profileName: widget.profileName,
          workspaceName: widget.workspaceName,
          joinCode: widget.joinCode,
        );
    if (!mounted) return;
    final state = ref.read(currentUserProvider);
    if (state.hasError || state.value == null) {
      final rawError = state.error?.toString() ?? '';
      String userError = 'Verification failed. Check the code and try again.';
      if (rawError.contains('invalid') || rawError.contains('expired')) {
        userError =
            'Invalid or expired code. Please enter the code again or resend.';
      }
      setState(() {
        _verifying = false;
        _error = userError;
      });
      return;
    }
    Navigator.of(context).pop();
  }

  Future<void> _resend() async {
    if (_cooldownSeconds > 0) return;
    setState(() {
      _resending = true;
      _error = null;
    });
    try {
      await ref.read(authRepositoryProvider).resendSignUpOtp(widget.email);
      if (mounted) {
        _startCooldownTimer(60);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('A new verification code was sent to your email.'),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        final errStr = error.toString();
        if (errStr.contains('rate_limit') ||
            errStr.contains('429') ||
            errStr.contains('Email rate limit')) {
          _error =
              'Email limit reached (3 per hour for test SMTP). Please wait a few minutes or check your inbox/spam folder.';
        } else {
          _error = 'Could not send verification code: $error';
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
      appBar: AppBar(title: const Text('Verify your email')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            CircleAvatar(
              radius: 34,
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Icon(
                Icons.mark_email_read_outlined,
                size: 34,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Check your inbox & spam folder',
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Enter the verification code sent to ${widget.email}.\n${widget.joinCode.isEmpty ? 'Your company workspace will be created automatically.' : 'You will join the company assigned to your code.'}',
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
              onSubmitted: (_) => _verify(),
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
            if (_error != null) ...[
              const SizedBox(height: 12),
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
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _verifying ? null : _verify,
              icon: _verifying
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.verified_user_outlined),
              label: Text(_verifying ? 'Verifying...' : 'Verify and continue'),
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
                        ? 'Resend code in ${_cooldownSeconds}s'
                        : 'Resend code',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
