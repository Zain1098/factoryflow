import 'package:supabase_flutter/supabase_flutter.dart';
import 'admin_models.dart';

class AdminRepository {
  const AdminRepository(this._client); final SupabaseClient _client;
  Future<bool> isPlatformAdmin() async => (await _client.rpc('is_platform_admin')) == true;
  Future<AdminDashboard> dashboard() async => AdminDashboard.fromJson(Map<String,dynamic>.from(await _client.rpc('platform_dashboard') as Map));
  Future<List<AdminUser>> users(String query) async => (await _client.rpc('platform_list_users', params:{'p_query':query}) as List).map((e)=>AdminUser.fromJson(Map<String,dynamic>.from(e as Map))).toList();
  Future<List<AdminWorkspace>> workspaces(String query) async => (await _client.rpc('platform_list_workspaces', params:{'p_query':query}) as List).map((e)=>AdminWorkspace.fromJson(Map<String,dynamic>.from(e as Map))).toList();
  Future<List<AdminAudit>> audit() async => (await _client.rpc('platform_list_audit') as List).map((e)=>AdminAudit.fromJson(Map<String,dynamic>.from(e as Map))).toList();
  Future<void> setUserBlocked(String id, bool blocked, String reason) => _client.rpc('platform_set_user_block',params:{'p_user_id':id,'p_blocked':blocked,'p_reason':reason});
  Future<void> setWorkspaceStatus(String id,String status,String reason) => _client.rpc('platform_set_workspace_status',params:{'p_workspace_id':id,'p_status':status,'p_reason':reason});
  Future<void> setMaintenance({required bool enabled,required String title,required String message}) => _client.rpc('platform_set_maintenance',params:{'p_enabled':enabled,'p_title':title,'p_message':message});
}
