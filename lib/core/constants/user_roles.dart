enum UserRole {
  owner('owner'),
  admin('Admin'),
  productionIncharge('Production Incharge'),
  store('Store'),
  qualityInspector('Quality Inspector'),
  /// Read-only business reporting role. The database value is kept as Viewer
  /// so Flutter, workspace_members and Supabase RLS share one vocabulary.
  management('Viewer');

  const UserRole(this.value);
  final String value;

  static UserRole? fromValue(String value) {
    // Backward compatibility for locally cached sessions from before the
    // shared-workspace role model was standardised.
    if (value == 'Management') return UserRole.management;
    for (final role in UserRole.values) {
      if (role.value == value) return role;
    }
    return null;
  }

  bool get canCreateTransactions => this != UserRole.management;

  bool get canManageMasters => this == UserRole.admin || this == UserRole.owner;

  bool get canApproveCorrections => this == UserRole.admin || this == UserRole.owner;

  /// Manual stock reconciliation changes the financial/operational source of
  /// truth, so it is deliberately narrower than normal transaction entry.
  bool get canAdjustStock => this == UserRole.admin || this == UserRole.owner;

  bool canAccessModule(String module) {
    if (this == UserRole.admin || this == UserRole.owner) return true;
    if (this == UserRole.management) return false;
    switch (module) {
      case 'material_receive':
      case 'dispatch_faco':
      case 'receive_faco':
      case 'final_dispatch':
        return this == UserRole.store;
      case 'production':
      case 'machine_downtime':
        return this == UserRole.productionIncharge;
      case 'bp_inspection':
      case 'ap_inspection':
      case 'rtv':
      case 'rtv_reinspection':
        return this == UserRole.qualityInspector;
      default:
        return false;
    }
  }
}
