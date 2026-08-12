import 'package:flutter_test/flutter_test.dart';
import 'package:factoryflow/features/admin_control/admin_models.dart';

void main() {
  test('dashboard DTO safely defaults missing counters', () {
    final dashboard = AdminDashboard.fromJson(const {'maintenance': {'enabled': true}});
    expect(dashboard.workspaces, 0);
    expect(dashboard.maintenance['enabled'], isTrue);
  });

  test('user DTO uses safe display fallbacks', () {
    final user = AdminUser.fromJson(const {'id': 'u1', 'active': false});
    expect(user.name, 'Unnamed');
    expect(user.active, isFalse);
  });
}
