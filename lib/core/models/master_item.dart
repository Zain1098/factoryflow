import 'package:equatable/equatable.dart';

class MasterItem extends Equatable {
  const MasterItem({
    required this.id,
    required this.name,
    this.code,
    this.active = true,
    this.extra,
  });

  final String id;
  final String name;
  final String? code;
  final bool active;
  final Map<String, dynamic>? extra;

  factory MasterItem.fromJson(Map<String, dynamic> json, {String nameKey = 'name'}) {
    return MasterItem(
      id: json['id'] as String,
      name: json[nameKey] as String,
      code: json['code'] as String?,
      active: json['active'] as bool? ?? true,
      extra: json,
    );
  }

  @override
  List<Object?> get props => [id, name, code, active];
}
