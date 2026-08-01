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
  });

  final String email;
  final String profileName;
  final String workspaceName;

  @override
  ConsumerState<SignupVerificationScreen> createState() =>
      _SignupVerificationScreenState();
}

class _SignupVerificationScreenState
    extends ConsumerState<SignupVerificationScreen> {
  final _otpController = TextEditingController();
  bool _verifying = false;
  bool _resending = false;
  String? _error;

  @override
  void dispose() {
    _otpController.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    final token = _otpController.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(token)) {
      setState(() => _error = 'Enter the 6-digit code from your email.');
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
        );
    if (!mounted) return;
    final state = ref.read(currentUserProvider);
    if (state.hasError || state.value == null) {
      setState(() {
        _verifying = false;
        _error = state.error?.toString() ??
            'Verification failed. Check the code and try again.';
      });
      return;
    }
    Navigator.of(context).pop();
  }

  Future<void> _resend() async {
    setState(() {
      _resending = true;
      _error = null;
    });
    try {
      await ref.read(authRepositoryProvider).resendSignUpOtp(widget.email);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('A new verification code was sent.')),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
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
              'Check your inbox',
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Enter the 6-digit code sent to ${widget.email}. Your company workspace will be created only after verification.',
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
              maxLength: 6,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onSubmitted: (_) => _verify(),
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: 8,
              ),
              decoration: const InputDecoration(
                labelText: 'Verification code',
                hintText: '000000',
                counterText: '',
                prefixIcon: Icon(Icons.password_outlined),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.colorScheme.error),
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
            TextButton(
              onPressed: _resending || _verifying ? null : _resend,
              child: Text(_resending ? 'Sending...' : 'Resend code'),
            ),
          ],
        ),
      ),
    );
  }
}
