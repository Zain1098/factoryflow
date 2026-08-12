import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../auth/auth_providers.dart';
import 'admin_models.dart';
import 'admin_repository.dart';

final adminRepositoryProvider = Provider<AdminRepository>((ref) { final client=ref.watch(supabaseClientProvider); if(client==null) throw StateError('Cloud connection is required for Admin Control.'); return AdminRepository(client); });
final isPlatformAdminProvider = FutureProvider<bool>((ref)=>ref.watch(adminRepositoryProvider).isPlatformAdmin());
final adminDashboardProvider = FutureProvider<AdminDashboard>((ref)=>ref.watch(adminRepositoryProvider).dashboard());
final adminUsersProvider = FutureProvider.family<List<AdminUser>,String>((ref,q)=>ref.watch(adminRepositoryProvider).users(q));
final adminWorkspacesProvider = FutureProvider.family<List<AdminWorkspace>,String>((ref,q)=>ref.watch(adminRepositoryProvider).workspaces(q));
final adminAuditProvider = FutureProvider<List<AdminAudit>>((ref)=>ref.watch(adminRepositoryProvider).audit());
final maintenanceStatusProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final client = ref.watch(supabaseClientProvider);
  if (client == null) return const {'enabled': false};
  final value = await client.rpc('platform_maintenance_status');
  return Map<String, dynamic>.from(value as Map);
});
