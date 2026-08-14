import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/models/app_user.dart';
import 'auth_providers.dart';
import 'otp_verification_screen.dart';

class AccountSettingsScreen extends ConsumerStatefulWidget {
  const AccountSettingsScreen({super.key});

  @override
  ConsumerState<AccountSettingsScreen> createState() =>
      _AccountSettingsScreenState();
}

class _AccountSettingsScreenState extends ConsumerState<AccountSettingsScreen> {
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _newPasswordController = TextEditingController();
  bool _isSavingName = false;
  bool _isSendingEmailOtp = false;
  bool _isSendingPasswordOtp = false;
  bool _isUploadingImage = false;

  @override
  void initState() {
    super.initState();
    final user = ref.read(currentUserProvider).value;
    if (user != null) {
      _nameController.text = user.name;
      _emailController.text = user.email;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _newPasswordController.dispose();
    super.dispose();
  }

  Future<void> _pickAndUploadAvatar() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 512,
      maxHeight: 512,
    );
    if (picked == null) return;

    setState(() => _isUploadingImage = true);
    final error =
        await ref.read(accountSettingsProvider.notifier).uploadAndUpdateAvatar(
              picked.path,
            );
    if (!mounted) return;
    setState(() => _isUploadingImage = false);

    if (error != null) {
      _showError(error);
    } else {
      _showSuccess('Profile picture updated.');
    }
  }

  Future<void> _saveName() async {
    final newName = _nameController.text.trim();
    if (newName.isEmpty) return;
    if (newName == ref.read(currentUserProvider).value?.name) return;

    setState(() => _isSavingName = true);
    final error =
        await ref.read(accountSettingsProvider.notifier).updateName(newName);
    if (!mounted) return;
    setState(() => _isSavingName = false);

    if (error != null) {
      _showError(error);
    } else {
      _showSuccess('Name updated successfully.');
    }
  }

  Future<void> _changeEmail() async {
    final newEmail = _emailController.text.trim();
    if (newEmail.isEmpty || !_validEmail(newEmail)) {
      _showError('Enter a valid email address.');
      return;
    }
    final user = ref.read(currentUserProvider).value;
    if (user != null && newEmail == user.email) {
      _showError('New email is the same as current email.');
      return;
    }

    setState(() => _isSendingEmailOtp = true);
    final error = await ref
        .read(accountSettingsProvider.notifier)
        .sendEmailChangeOtp(newEmail);
    if (!mounted) return;
    setState(() => _isSendingEmailOtp = false);

    if (error != null) {
      _showError(error);
      return;
    }

    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => OtpVerificationScreen(
          purpose: 'email_change',
          newValue: newEmail,
          onVerified: () {
            Navigator.pop(context);
            _showSuccess(
              'Security code accepted. Confirm the email sent to $newEmail to finish the change.',
            );
          },
        ),
      ),
    );
  }

  Future<void> _changePassword() async {
    final newPassword = _newPasswordController.text.trim();
    if (newPassword.length < 8) {
      _showError('Password must be at least 8 characters.');
      return;
    }

    setState(() => _isSendingPasswordOtp = true);
    final error = await ref
        .read(accountSettingsProvider.notifier)
        .sendPasswordChangeOtp(newPassword);
    if (!mounted) return;
    setState(() => _isSendingPasswordOtp = false);

    if (error != null) {
      _showError(error);
      return;
    }

    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => OtpVerificationScreen(
          purpose: 'password_change',
          newValue: newPassword,
          onVerified: () {
            Navigator.pop(context);
            _newPasswordController.clear();
            _showSuccess('Password changed successfully.');
          },
        ),
      ),
    );
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final user = ref.watch(currentUserProvider).value;
    final isGoogleUser = user?.authProvider == 'google';

    return Scaffold(
      appBar: AppBar(title: const Text('Account Settings')),
      body: ListView(
        padding: const EdgeInsets.only(top: 12, bottom: 28),
        children: [
          // ── Avatar Section ──
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Stack(
              children: [
                CircleAvatar(
                  radius: 36,
                  backgroundColor: theme.colorScheme.primaryContainer,
                  child: _buildAvatarContent(user),
                ),
                Positioned(
                  bottom: -2,
                  right: -2,
                  child: Material(
                    color: theme.colorScheme.primary,
                    borderRadius: BorderRadius.circular(20),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: _isUploadingImage ? null : _pickAndUploadAvatar,
                      child: Padding(
                        padding: const EdgeInsets.all(7),
                        child: _isUploadingImage
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(
                                Icons.camera_alt,
                                color: Colors.white,
                                size: 17,
                              ),
                      ),
                    ),
                  ),
                ),
                  ],
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(user?.name ?? 'Your profile',
                            style: theme.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),),
                        const SizedBox(height: 3),
                        Text(user?.email ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,),),
                        const SizedBox(height: 5),
                        Text('Tap camera to update photo',
                            style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.primary,),),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── Account Info Card ──
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Account Info',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    isGoogleUser
                        ? 'You signed in with Google. Change email in your Google account settings.'
                        : 'Changes to email require OTP verification.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Name
                  TextFormField(
                    controller: _nameController,
                    decoration: InputDecoration(
                      labelText: 'Name',
                      prefixIcon: const Icon(Icons.person_outline),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.tonalIcon(
                      onPressed: _isSavingName ? null : _saveName,
                      icon: _isSavingName
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.save_outlined, size: 18),
                      label: Text(_isSavingName ? 'Saving...' : 'Save Name'),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Email (only editable for non-Google users)
                  TextFormField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    readOnly: isGoogleUser,
                    decoration: InputDecoration(
                      labelText: 'Email',
                      prefixIcon: const Icon(Icons.email_outlined),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      suffixIcon: isGoogleUser
                          ? const Icon(Icons.lock_outline, size: 18)
                          : null,
                      helperText: isGoogleUser
                          ? 'Managed by Google'
                          : 'OTP will be sent to current email',
                    ),
                  ),
                  if (!isGoogleUser) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.tonalIcon(
                        onPressed: _isSendingEmailOtp ? null : _changeEmail,
                        icon: _isSendingEmailOtp
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.email_outlined, size: 18),
                        label: Text(
                          _isSendingEmailOtp
                              ? 'Sending OTP...'
                              : 'Change Email',
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ── Password Card (only for non-Google users) ──
          if (!isGoogleUser)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Change Password',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'OTP will be sent to your current email for verification.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _newPasswordController,
                      obscureText: true,
                      decoration: InputDecoration(
                        labelText: 'New Password',
                        prefixIcon: const Icon(Icons.lock_outlined),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.tonalIcon(
                        onPressed:
                            _isSendingPasswordOtp ? null : _changePassword,
                        icon: _isSendingPasswordOtp
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.lock_reset_outlined, size: 18),
                        label: Text(
                          _isSendingPasswordOtp
                              ? 'Sending OTP...'
                              : 'Change Password',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // ── Session Info ──
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Session Info',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _infoRow(
                    Icons.account_circle_outlined,
                    'Signed in with',
                    isGoogleUser ? 'Google' : 'Email & Password',
                  ),
                  _infoRow(
                    Icons.access_time,
                    'Session expires',
                    '14 days after login',
                  ),
                  if (user?.sessionCreatedAt != null)
                    _infoRow(
                      Icons.login,
                      'Last sign-in',
                      _formatDate(user!.sessionCreatedAt!),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatarContent(AppUser? user) {
    final url = user?.avatarUrl?.trim();
    if (url != null && url.isNotEmpty) {
      return ClipOval(
        child: Image.network(
          url,
          width: 112,
          height: 112,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _buildDefaultAvatar(user),
          loadingBuilder: (context, child, loadingProgress) {
            if (loadingProgress == null) return child;
            return CircularProgressIndicator(
              value: loadingProgress.expectedTotalBytes != null
                  ? loadingProgress.cumulativeBytesLoaded /
                      loadingProgress.expectedTotalBytes!
                  : null,
            );
          },
        ),
      );
    }
    return _buildDefaultAvatar(user);
  }

  Widget _buildDefaultAvatar(AppUser? user) {
    if (user == null || user.name.isEmpty) {
      return const Icon(Icons.person, size: 48, color: Colors.grey);
    }
    return Text(
      user.name[0].toUpperCase(),
      style: const TextStyle(fontSize: 36, fontWeight: FontWeight.bold),
    );
  }

  Widget _infoRow(IconData icon, String label, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Text(
            '$label: ',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${dt.day} ${months[dt.month - 1]} ${dt.year}, '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
  }
}
