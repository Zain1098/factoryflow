import 'dart:convert';
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ProductionMode {
  multiStageSequential(
      'multi_stage', 'Multi-Stage Machine Sequence (WIP -> Final)',),
  directSingleStage('direct_single', 'Direct Single-Stage Production');

  const ProductionMode(this.code, this.label);
  final String code;
  final String label;

  static ProductionMode fromCode(String? code) {
    if (code == 'direct_single') return ProductionMode.directSingleStage;
    return ProductionMode.multiStageSequential;
  }
}

/// Defines the one official quantity used by dashboard KPIs, reports, and
/// production alerts for this factory.
enum ProductionCountingMode {
  completedOutput('completed_output', 'Completed PCS (Final Output)'),
  stageWorkload('stage_workload', 'Stage Workload (All Machines)');

  const ProductionCountingMode(this.code, this.label);

  final String code;
  final String label;

  static ProductionCountingMode fromCode(String? code) {
    if (code == stageWorkload.code) return stageWorkload;
    return completedOutput;
  }
}

/// Defines machine sequence and production routing logic.
class ProductionFlowConfig {
  const ProductionFlowConfig({
    this.enabled = false,
    this.productionMode = ProductionMode.multiStageSequential,
    this.countingMode = ProductionCountingMode.completedOutput,
    this.requireFinalMachineForDispatch = true,
    this.requiredMachineIds = const [],
  });

  final bool enabled;
  final ProductionMode productionMode;
  final ProductionCountingMode countingMode;
  final bool requireFinalMachineForDispatch;
  final List<String> requiredMachineIds;

  bool get isMultiStage =>
      enabled &&
      productionMode == ProductionMode.multiStageSequential &&
      requiredMachineIds.isNotEmpty;

  bool get countsAllStageOutput =>
      countingMode == ProductionCountingMode.stageWorkload;

  String? get validationError {
    if (enabled &&
        productionMode == ProductionMode.multiStageSequential &&
        requiredMachineIds.isEmpty) {
      return 'Multi-stage production is enabled, but no machine sequence is configured.';
    }
    return null;
  }

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
    ProductionCountingMode? countingMode,
    bool? requireFinalMachineForDispatch,
    List<String>? requiredMachineIds,
  }) {
    return ProductionFlowConfig(
      enabled: enabled ?? this.enabled,
      productionMode: productionMode ?? this.productionMode,
      countingMode: countingMode ?? this.countingMode,
      requireFinalMachineForDispatch:
          requireFinalMachineForDispatch ?? this.requireFinalMachineForDispatch,
      requiredMachineIds: requiredMachineIds ?? this.requiredMachineIds,
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'productionMode': productionMode.code,
        'countingMode': countingMode.code,
        'requireFinalMachineForDispatch': requireFinalMachineForDispatch,
        'requiredMachineIds': requiredMachineIds,
      };

  factory ProductionFlowConfig.fromJson(Map<String, dynamic> j) {
    return ProductionFlowConfig(
      enabled: j['enabled'] as bool? ?? false,
      productionMode: ProductionMode.fromCode(j['productionMode'] as String?),
      countingMode: ProductionCountingMode.fromCode(
        j['countingMode'] as String?,
      ),
      requireFinalMachineForDispatch:
          j['requireFinalMachineForDispatch'] as bool? ?? true,
      requiredMachineIds: (j['requiredMachineIds'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
    );
  }
}

// ─── Notifier ─────────────────────────────────────────────────────────────────

ProductionFlowConfig repairProductionFlowConfig(
  ProductionFlowConfig config,
  List<Map<String, dynamic>> machines,
) {
  if (!config.enabled ||
      config.productionMode != ProductionMode.multiStageSequential) {
    return config;
  }

  final activeMachines =
      machines.where((machine) => machine['active'] != 0).toList()
        ..sort(
          (a, b) => ((a['sequence_order'] as num?)?.toInt() ?? 0)
              .compareTo((b['sequence_order'] as num?)?.toInt() ?? 0),
        );
  final activeIds =
      activeMachines.map((machine) => machine['id'] as String).toSet();
  var repairedIds = config.requiredMachineIds
      .where(activeIds.contains)
      .toList(growable: false);

  // Older versions could persist enabled=true without the sequence.
  if (repairedIds.isEmpty && activeMachines.isNotEmpty) {
    repairedIds = activeMachines
        .map((machine) => machine['id'] as String)
        .toList(growable: false);
  }

  final unchanged = repairedIds.length == config.requiredMachineIds.length &&
      repairedIds.asMap().entries.every(
            (entry) => config.requiredMachineIds[entry.key] == entry.value,
          );
  return unchanged ? config : config.copyWith(requiredMachineIds: repairedIds);
}

class ProductionFlowNotifier extends Notifier<ProductionFlowConfig> {
  static const _key = 'production_flow_config';
  Completer<void>? _loadCompleter;
  String? _loadError;

  String? get loadError => _loadError;

  @override
  ProductionFlowConfig build() {
    _loadCompleter = Completer<void>();
    _load();
    return const ProductionFlowConfig();
  }

  Future<void> ensureLoaded() => _loadCompleter?.future ?? Future.value();

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw != null) {
        state = ProductionFlowConfig.fromJson(
            jsonDecode(raw) as Map<String, dynamic>,);
      }
    } catch (error) {
      _loadError = 'Production flow settings could not load: $error';
    } finally {
      if (!(_loadCompleter?.isCompleted ?? true)) {
        _loadCompleter!.complete();
      }
    }
  }

  Future<void> save(ProductionFlowConfig config) async {
    final previous = state;
    state = config;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(config.toJson()));
      _loadError = null;
    } catch (error) {
      state = previous;
      _loadError = 'Production flow settings could not be saved.';
      throw StateError(_loadError!);
    }
  }

  Future<void> setEnabled(bool v) => save(state.copyWith(enabled: v));

  Future<void> setProductionMode(ProductionMode mode) =>
      save(state.copyWith(productionMode: mode));

  Future<void> setCountingMode(ProductionCountingMode mode) =>
      save(state.copyWith(countingMode: mode));

  Future<void> setRequireFinalMachineForDispatch(bool v) =>
      save(state.copyWith(requireFinalMachineForDispatch: v));

  Future<void> setRequiredMachines(List<String> ids) =>
      save(state.copyWith(requiredMachineIds: ids));
}

final productionFlowProvider =
    NotifierProvider<ProductionFlowNotifier, ProductionFlowConfig>(
  ProductionFlowNotifier.new,
);
