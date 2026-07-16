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
    this.avatarUrl,
    this.authProvider = 'email',
    this.active = true,
    this.sessionCreatedAt,
  });

  final String id;
  final String factoryId;
  final String name;
  final String email;
  final String? phone;
  final String? avatarUrl;
  final String authProvider; // 'email' or 'google'
  final UserRole role;
  final bool active;
  final DateTime? sessionCreatedAt;

  factory AppUser.fromJson(Map<String, dynamic> json) {
    return AppUser(
      id: json['id'] as String,
      factoryId: json['factory_id'] as String,
      name: json['name'] as String,
      email: json['email'] as String? ?? '',
      phone: json['phone'] as String?,
      avatarUrl: json['avatar_url'] as String?,
      authProvider: json['auth_provider'] as String? ?? 'email',
      role: UserRole.fromValue(json['role'] as String) ?? UserRole.management,
      active: json['active'] as bool? ?? true,
      sessionCreatedAt: json['session_created_at'] != null
          ? DateTime.tryParse(json['session_created_at'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'factory_id': factoryId,
        'name': name,
        'email': email,
        'phone': phone,
        'avatar_url': avatarUrl,
        'auth_provider': authProvider,
        'role': role.value,
        'active': active,
        'session_created_at': sessionCreatedAt?.toIso8601String(),
      };

  AppUser copyWith({
    String? id,
    String? factoryId,
    String? name,
    String? email,
    String? phone,
    String? avatarUrl,
    String? authProvider,
    UserRole? role,
    bool? active,
    DateTime? sessionCreatedAt,
  }) {
    return AppUser(
      id: id ?? this.id,
      factoryId: factoryId ?? this.factoryId,
      name: name ?? this.name,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      authProvider: authProvider ?? this.authProvider,
      role: role ?? this.role,
      active: active ?? this.active,
      sessionCreatedAt: sessionCreatedAt ?? this.sessionCreatedAt,
    );
  }

  @override
  List<Object?> get props => [id, factoryId, name, email, role, active, avatarUrl, authProvider];
}
