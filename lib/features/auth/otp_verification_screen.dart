import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_providers.dart';

class OtpVerificationScreen extends ConsumerStatefulWidget {
  const OtpVerificationScreen({
    super.key,
    required this.purpose,
    required this.newValue,
    required this.onVerified,
  });

  final String purpose; // 'email_change' or 'password_change'
  final String newValue;
  final VoidCallback onVerified;

  @override
  ConsumerState<OtpVerificationScreen> createState() =>
      _OtpVerificationScreenState();
}

class _OtpVerificationScreenState extends ConsumerState<OtpVerificationScreen> {
  final _otpController = TextEditingController();
  bool _isVerifying = false;
  String? _error;

  @override
  void dispose() {
    _otpController.dispose();
    super.dispose();
  }

  String get _title {
    switch (widget.purpose) {
      case 'email_change':
        return 'Verify Email Change';
      case 'password_change':
        return 'Verify Password Change';
      default:
        return 'Verify OTP';
    }
  }

  String get _description {
    switch (widget.purpose) {
      case 'email_change':
        return 'An OTP has been sent to your current email. Enter it below to confirm the email change to ${widget.newValue}.';
      case 'password_change':
        return 'An OTP has been sent to your current email. Enter it below to confirm the password change.';
      default:
        return 'Enter the OTP sent to your email.';
    }
  }

  Future<void> _verify() async {
    final code = _otpController.text.trim();
    if (!RegExp(r'^\d{6,10}$').hasMatch(code)) {
      setState(() => _error = 'Enter a valid 6 to 10 digit security code.');
      return;
    }

    setState(() {
      _isVerifying = true;
      _error = null;
    });

    String? error;
    if (widget.purpose == 'email_change') {
      error =
          await ref.read(accountSettingsProvider.notifier).verifyEmailChangeOtp(
                code,
                widget.newValue,
              );
    } else {
      error = await ref
          .read(accountSettingsProvider.notifier)
          .verifyPasswordChangeOtp(
            code,
            widget.newValue,
          );
    }

    if (!mounted) return;

    if (error != null) {
      setState(() {
        _isVerifying = false;
        _error = error;
      });
    } else {
      widget.onVerified();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(_title)),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 16),
            Icon(
              Icons.security_outlined,
              size: 64,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              _title,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              _description,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            TextField(
              controller: _otpController,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              maxLength: 10,
              enabled: !_isVerifying,
              decoration: InputDecoration(
                hintText: '0000000000',
                labelText: 'Security code (6–10 digits)',
                counterText: '',
                prefixIcon: const Icon(Icons.pin_outlined),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
                letterSpacing: 8,
              ),
              onSubmitted: (_) => _verify(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
                        style: TextStyle(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _isVerifying ? null : _verify,
              style: FilledButton.styleFrom(
                minimumSize: const Size(double.infinity, 50),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: _isVerifying
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: Colors.white,
                      ),
                    )
                  : const Text(
                      'Verify OTP',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
