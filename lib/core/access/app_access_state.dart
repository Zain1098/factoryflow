import 'package:flutter_riverpod/flutter_riverpod.dart';

enum AppAccessStatus { checking, allowed, maintenance, unavailable, blocked }

/// The access gate must distinguish an explicitly inactive profile from one
/// that has not been provisioned or cannot currently be read. Only an
/// explicitly inactive profile is grounds for signing the authenticated user
/// out; the other case remains fail-closed without destroying the session.
enum AppProfileVerification { active, inactive, unresolved }

AppProfileVerification verifyProfileActivity(Object? active) {
  if (active == true) return AppProfileVerification.active;
  if (active == false) return AppProfileVerification.inactive;
  return AppProfileVerification.unresolved;
}

class AppAccessState {
  const AppAccessState({
    required this.status,
    this.title,
    this.message,
  });

  const AppAccessState.checking() : this(status: AppAccessStatus.checking);

  final AppAccessStatus status;
  final String? title;
  final String? message;

  bool get isAllowed => status == AppAccessStatus.allowed;
  bool get blocksProtectedRoutes =>
      status == AppAccessStatus.checking || status == AppAccessStatus.maintenance ||
      status == AppAccessStatus.unavailable || status == AppAccessStatus.blocked;
}

/// This state is deliberately independent from the ERP providers. Sync and the
/// router use it as a last client-side guard; RLS/RPCs remain authoritative.
final appAccessProvider = NotifierProvider<AppAccessNotifier, AppAccessState>(
  AppAccessNotifier.new,
);

class AppAccessNotifier extends Notifier<AppAccessState> {
  @override
  AppAccessState build() => const AppAccessState.checking();

  void set(AppAccessState value) => state = value;
}
