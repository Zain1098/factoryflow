import 'package:equatable/equatable.dart';

import '../constants/user_roles.dart';

class AppUser extends Equatable {
  const AppUser({
    required this.id,
    required this.factoryId,
    required this.name,
    required this.email,
    required this.role,
    this.phone,
    this.active = true,
  });

  final String id;
  final String factoryId;
  final String name;
  final String email;
  final String? phone;
  final UserRole role;
  final bool active;

  factory AppUser.fromJson(Map<String, dynamic> json) {
    return AppUser(
      id: json['id'] as String,
      factoryId: json['factory_id'] as String,
      name: json['name'] as String,
      email: json['email'] as String? ?? '',
      phone: json['phone'] as String?,
      role: UserRole.fromValue(json['role'] as String) ?? UserRole.management,
      active: json['active'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'factory_id': factoryId,
        'name': name,
        'email': email,
        'phone': phone,
        'role': role.value,
        'active': active,
      };

  @override
  List<Object?> get props => [id, factoryId, name, email, role, active];
}
