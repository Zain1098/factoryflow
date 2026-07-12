enum UserRole {
  admin('Admin'),
  productionIncharge('Production Incharge'),
  store('Store'),
  qualityInspector('Quality Inspector'),
  management('Management');

  const UserRole(this.value);
  final String value;

  static UserRole? fromValue(String value) {
    for (final role in UserRole.values) {
      if (role.value == value) return role;
    }
    return null;
  }

  bool get canCreateTransactions => this != UserRole.management;

  bool get canManageMasters => this == UserRole.admin;

  bool get canApproveCorrections => this == UserRole.admin;

  bool canAccessModule(String module) {
    if (this == UserRole.admin) return true;
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
