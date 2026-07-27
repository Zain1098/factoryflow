import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ProductionMode {
  multiStageSequential('multi_stage', 'Multi-Stage Machine Sequence (WIP -> Final)'),
  directSingleStage('direct_single', 'Direct Single-Stage Production');

  const ProductionMode(this.code, this.label);
  final String code;
  final String label;

  static ProductionMode fromCode(String? code) {
    if (code == 'direct_single') return ProductionMode.directSingleStage;
    return ProductionMode.multiStageSequential;
  }
}

/// Defines machine sequence and production routing logic.
class ProductionFlowConfig {
  const ProductionFlowConfig({
    this.enabled = false,
    this.productionMode = ProductionMode.multiStageSequential,
    this.requireFinalMachineForDispatch = true,
    this.requiredMachineIds = const [],
  });

  final bool enabled;
  final ProductionMode productionMode;
  final bool requireFinalMachineForDispatch;
  final List<String> requiredMachineIds;

  bool get isMultiStage => enabled && productionMode == ProductionMode.multiStageSequential && requiredMachineIds.isNotEmpty;

  /// Checks if a given machine ID is the final machine in the sequence
  bool isFinalMachine(String machineId) {
    if (!isMultiStage) return true;
    if (requiredMachineIds.isEmpty) return true;
    return requiredMachineIds.last == machineId;
  }

  /// Returns 1-based sequence order of a machine ID in the sequence list (or 0 if not found)
  int getMachineSequenceIndex(String machineId) {
    final idx = requiredMachineIds.indexOf(machineId);
    return idx >= 0 ? idx + 1 : 0;
  }

  /// Returns the next machine ID required after [currentMachineId]
  String? getNextMachineId(String currentMachineId) {
    final idx = requiredMachineIds.indexOf(currentMachineId);
    if (idx >= 0 && idx + 1 < requiredMachineIds.length) {
      return requiredMachineIds[idx + 1];
    }
    return null;
  }

  ProductionFlowConfig copyWith({
    bool? enabled,
    ProductionMode? productionMode,
    bool? requireFinalMachineForDispatch,
    List<String>? requiredMachineIds,
  }) {
    return ProductionFlowConfig(
      enabled: enabled ?? this.enabled,
      productionMode: productionMode ?? this.productionMode,
      requireFinalMachineForDispatch: requireFinalMachineForDispatch ?? this.requireFinalMachineForDispatch,
      requiredMachineIds: requiredMachineIds ?? this.requiredMachineIds,
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'productionMode': productionMode.code,
        'requireFinalMachineForDispatch': requireFinalMachineForDispatch,
        'requiredMachineIds': requiredMachineIds,
      };

  factory ProductionFlowConfig.fromJson(Map<String, dynamic> j) {
    return ProductionFlowConfig(
      enabled: j['enabled'] as bool? ?? false,
      productionMode: ProductionMode.fromCode(j['productionMode'] as String?),
      requireFinalMachineForDispatch: j['requireFinalMachineForDispatch'] as bool? ?? true,
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

  Future<void> setProductionMode(ProductionMode mode) => save(state.copyWith(productionMode: mode));

  Future<void> setRequireFinalMachineForDispatch(bool v) =>
      save(state.copyWith(requireFinalMachineForDispatch: v));

  Future<void> setRequiredMachines(List<String> ids) =>
      save(state.copyWith(requiredMachineIds: ids));
}

final productionFlowProvider =
    NotifierProvider<ProductionFlowNotifier, ProductionFlowConfig>(
        ProductionFlowNotifier.new,);
