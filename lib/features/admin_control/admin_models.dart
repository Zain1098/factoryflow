class AdminDashboard {
  const AdminDashboard({required this.workspaces, required this.activeUsers, required this.blockedUsers, required this.pendingInvites, required this.maintenance, required this.events});
  final int workspaces, activeUsers, blockedUsers, pendingInvites;
  final Map<String, dynamic> maintenance;
  final List<Map<String, dynamic>> events;
  factory AdminDashboard.fromJson(Map<String, dynamic> json) => AdminDashboard(
    workspaces: (json['workspaces'] as num? ?? 0).toInt(), activeUsers: (json['active_users'] as num? ?? 0).toInt(), blockedUsers: (json['blocked_users'] as num? ?? 0).toInt(), pendingInvites: (json['pending_invites'] as num? ?? 0).toInt(),
    maintenance: Map<String, dynamic>.from(json['maintenance'] as Map? ?? const {}), events: (json['recent_events'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList());
}

class AdminUser { const AdminUser(this.id,this.name,this.email,this.role,this.active,this.workspace); final String id,name,email,role,workspace; final bool active; factory AdminUser.fromJson(Map<String,dynamic> j)=>AdminUser('${j['id']}',j['name'] as String? ?? 'Unnamed',j['email'] as String? ?? '',j['role'] as String? ?? '',j['active'] as bool? ?? false,j['workspace_name'] as String? ?? 'Unknown workspace'); }
class AdminWorkspace { const AdminWorkspace(this.id,this.name,this.status,this.members); final String id,name,status; final int members; factory AdminWorkspace.fromJson(Map<String,dynamic> j)=>AdminWorkspace('${j['id']}',j['name'] as String? ?? 'Unnamed',j['status'] as String? ?? 'active',(j['member_count'] as num? ?? 0).toInt()); }
class AdminAudit { const AdminAudit(this.action,this.result,this.occurredAt,this.metadata); final String action,result,occurredAt; final Map<String,dynamic> metadata; factory AdminAudit.fromJson(Map<String,dynamic> j)=>AdminAudit(j['action'] as String? ?? 'unknown',j['result'] as String? ?? 'failed',j['occurred_at'] as String? ?? '',Map<String,dynamic>.from(j['metadata'] as Map? ?? const {})); }
