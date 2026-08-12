import 'package:factoryflow/core/access/app_access_state.dart';
import 'package:factoryflow/core/database/database_service.dart';
import 'package:factoryflow/core/network/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('active user with maintenance off can enter protected app', () {
    const state = AppAccessState(status: AppAccessStatus.allowed);
    expect(state.isAllowed, isTrue);
    expect(state.blocksProtectedRoutes, isFalse);
  });

  test('maintenance, block, and verification failure all fail closed', () {
    const maintenance = AppAccessState(status: AppAccessStatus.maintenance);
    const blocked = AppAccessState(status: AppAccessStatus.blocked);
    const unavailable = AppAccessState(status: AppAccessStatus.unavailable);

    expect(maintenance.blocksProtectedRoutes, isTrue);
    expect(blocked.blocksProtectedRoutes, isTrue);
    expect(unavailable.blocksProtectedRoutes, isTrue);
  });

  test('only an explicitly inactive profile is a block decision', () {
    expect(verifyProfileActivity(true), AppProfileVerification.active);
    expect(verifyProfileActivity(false), AppProfileVerification.inactive);
    expect(verifyProfileActivity(null), AppProfileVerification.unresolved);
  });

  test('sync is skipped while access is not allowed', () async {
    final sync = SyncService(
      DatabaseService.instance,
      accessAllowed: () => false,
      onlineCheck: () async => true,
    );

    final result = await sync.syncPending();
    expect(result.skipped, isTrue);
  });
}
