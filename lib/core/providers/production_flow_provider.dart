import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─── Model ────────────────────────────────────────────────────────────────────

/// Defines which machines must ALL complete before a part batch is "Ready".
/// If requiredMachineIds is empty → single-machine mode (old behaviour).
class ProductionFlowConfig {
  const ProductionFlowConfig({
    this.enabled = false,
    this.requiredMachineIds = const [],
  });

  final bool enabled;
  final List<String> requiredMachineIds;

  ProductionFlowConfig copyWith({bool? enabled, List<String>? requiredMachineIds}) {
    return ProductionFlowConfig(
      enabled: enabled ?? this.enabled,
      requiredMachineIds: requiredMachineIds ?? this.requiredMachineIds,
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'requiredMachineIds': requiredMachineIds,
      };

  factory ProductionFlowConfig.fromJson(Map<String, dynamic> j) {
    return ProductionFlowConfig(
      enabled: j['enabled'] as bool? ?? false,
      requiredMachineIds: (j['requiredMachineIds'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
    );
  }
}

// ─── Notifier ─────────────────────────────────────────────────────────────────

class ProductionFlowNotifier extends Notifier<ProductionFlowConfig> {
  static const _key = 'production_flow_config';

  @override
  ProductionFlowConfig build() {
    _load();
    return const ProductionFlowConfig();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null) {
      try {
        state = ProductionFlowConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      } catch (_) {}
    }
  }

  Future<void> save(ProductionFlowConfig config) async {
    state = config;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(config.toJson()));
  }

  Future<void> setEnabled(bool v) => save(state.copyWith(enabled: v));

  Future<void> setRequiredMachines(List<String> ids) =>
      save(state.copyWith(requiredMachineIds: ids));
}

final productionFlowProvider =
    NotifierProvider<ProductionFlowNotifier, ProductionFlowConfig>(
        ProductionFlowNotifier.new,);
