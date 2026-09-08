import 'package:factoryflow/core/providers/production_flow_provider.dart';
import 'package:factoryflow/features/production/production_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const machines = [
    {
      'id': 'machine-2',
      'name': 'Notching',
      'sequence_order': 2,
      'active': 1,
    },
    {
      'id': 'machine-1',
      'name': 'Bending',
      'sequence_order': 1,
      'active': 1,
    },
    {
      'id': 'machine-old',
      'name': 'Old Machine',
      'sequence_order': 0,
      'active': 0,
    },
  ];

  test('legacy enabled flow recovers the active machine sequence', () {
    final repaired = repairProductionFlowConfig(
      const ProductionFlowConfig(enabled: true),
      machines,
    );

    expect(repaired.requiredMachineIds, ['machine-1', 'machine-2']);
    expect(repaired.validationError, isNull);
    expect(repaired.isMultiStage, isTrue);
  });

  test('saved valid sequence order is preserved', () {
    const config = ProductionFlowConfig(
      enabled: true,
      requiredMachineIds: ['machine-2', 'machine-1'],
    );

    final repaired = repairProductionFlowConfig(config, machines);

    expect(identical(repaired, config), isTrue);
    expect(repaired.requiredMachineIds, ['machine-2', 'machine-1']);
  });

  test('direct production mode does not invent a machine sequence', () {
    const config = ProductionFlowConfig(
      enabled: true,
      productionMode: ProductionMode.directSingleStage,
    );

    final repaired = repairProductionFlowConfig(config, machines);

    expect(identical(repaired, config), isTrue);
    expect(repaired.requiredMachineIds, isEmpty);
    expect(repaired.validationError, isNull);
  });

  test('completed output remains the default company KPI rule', () {
    const config = ProductionFlowConfig();

    expect(config.countingMode, ProductionCountingMode.completedOutput);
    expect(config.countsAllStageOutput, isFalse);
  });

  test('stage workload KPI mode survives configuration serialization', () {
    const config = ProductionFlowConfig(
      countingMode: ProductionCountingMode.stageWorkload,
    );

    final restored = ProductionFlowConfig.fromJson(config.toJson());

    expect(restored.countingMode, ProductionCountingMode.stageWorkload);
    expect(restored.countsAllStageOutput, isTrue);
  });

  group('calculatePartGoodTotals tests', () {
    const flow = ProductionFlowConfig(
      enabled: true,
      requiredMachineIds: ['m-cutting', 'm-bending', 'm-endforming'],
    );

    test('strictly sums ONLY final machine (End Forming) across shifts and ignores intermediate WIP', () {
      final records = [
        // Shift A Cutting (WIP)
        {'part_code': 'V21', 'machine_id': 'm-cutting', 'good_qty': 500, 'shift_id': 'A'},
        // Shift A Bending (WIP)
        {'part_code': 'V21', 'machine_id': 'm-bending', 'good_qty': 500, 'shift_id': 'A'},
        // Shift A End Forming (FINAL) -> 500
        {'part_code': 'V21', 'machine_id': 'm-endforming', 'good_qty': 500, 'shift_id': 'A'},

        // Shift B Cutting (WIP)
        {'part_code': 'V21', 'machine_id': 'm-cutting', 'good_qty': 450, 'shift_id': 'B'},
        // Shift B Bending (WIP)
        {'part_code': 'V21', 'machine_id': 'm-bending', 'good_qty': 450, 'shift_id': 'B'},
        // Shift B End Forming (FINAL) -> 450
        {'part_code': 'V21', 'machine_id': 'm-endforming', 'good_qty': 450, 'shift_id': 'B'},
      ];

      final totals = calculatePartGoodTotals(records, flow);

      // Must be 500 + 450 = 950 (NOT 2850!)
      expect(totals, {'V21': 950});
    });

    test('handles multiple parts correctly with final machine output', () {
      final records = [
        // V21 on End Forming
        {'part_code': 'V21', 'machine_id': 'm-endforming', 'good_qty': 300, 'shift_id': 'A'},
        // V67 on End Forming
        {'part_code': 'V67', 'machine_id': 'm-endforming', 'good_qty': 100, 'shift_id': 'A'},
        {'part_code': 'V67', 'machine_id': 'm-endforming', 'good_qty': 300, 'shift_id': 'B'},
        // Intermediate machine for V67
        {'part_code': 'V67', 'machine_id': 'm-bending', 'good_qty': 400, 'shift_id': 'B'},
      ];

      final totals = calculatePartGoodTotals(records, flow);

      expect(totals['V21'], 300);
      expect(totals['V67'], 400);
    });

    test('determines final machine from machines sequence_order if flow.requiredMachineIds is empty', () {
      const emptyFlow = ProductionFlowConfig();
      const testMachines = [
        {'id': 'm-cutting', 'name': 'Cutting', 'sequence_order': 1, 'active': 1},
        {'id': 'm-bending', 'name': 'Bending', 'sequence_order': 2, 'active': 1},
        {'id': 'm-endforming', 'name': 'End Forming', 'sequence_order': 3, 'active': 1},
      ];

      final records = [
        {'part_code': 'V21', 'machine_id': 'm-cutting', 'good_qty': 500},
        {'part_code': 'V21', 'machine_id': 'm-bending', 'good_qty': 500},
        {'part_code': 'V21', 'machine_id': 'm-endforming', 'good_qty': 500},
      ];

      final totals = calculatePartGoodTotals(records, emptyFlow, machines: testMachines);

      // Correctly identified m-endforming as sequence_order: 3
      expect(totals, {'V21': 500});
    });

    test('shows 0 when only intermediate WIP machines ran on that day', () {
      final records = [
        {'part_code': 'V21', 'machine_id': 'm-cutting', 'good_qty': 200},
        {'part_code': 'V21', 'machine_id': 'm-bending', 'good_qty': 150},
      ];

      final totals = calculatePartGoodTotals(records, flow);

      // 0 completed finished goods
      expect(totals, {'V21': 0});
    });

    test('sums End Forming 400 in Shift A and 500 in Shift B to exactly 900 across duplicate machine IDs', () {
      // Factory active machines (has two End Forming rows from sync/workspaces)
      const testMachines = [
        {'id': 'm-bending-1', 'name': 'Bending', 'sequence_order': 1, 'active': 1},
        {'id': 'm-notching-1', 'name': 'Notching', 'sequence_order': 2, 'active': 1},
        {'id': 'm-endforming-old', 'name': 'End Forming', 'sequence_order': 3, 'active': 1},
        {'id': 'm-endforming-new', 'name': 'End Forming', 'sequence_order': 3, 'active': 1},
      ];

      // flow config configured with m-endforming-new
      const testFlow = ProductionFlowConfig(
        enabled: true,
        requiredMachineIds: ['m-bending-1', 'm-notching-1', 'm-endforming-new'],
      );

      // Records created with m-endforming-old or by name
      final records = [
        // Shift A Bending (WIP) -> 400
        {'part_code': 'V21', 'machine_id': 'm-bending-1', 'machine_name': 'Bending', 'sequence_order': 1, 'good_qty': 400, 'shift_id': 'A'},
        // Shift A End Forming (FINAL) -> 400
        {'part_code': 'V21', 'machine_id': 'm-endforming-old', 'machine_name': 'End Forming', 'sequence_order': 3, 'good_qty': 400, 'shift_id': 'A'},

        // Shift B Bending (WIP) -> 500
        {'part_code': 'V21', 'machine_id': 'm-bending-1', 'machine_name': 'Bending', 'sequence_order': 1, 'good_qty': 500, 'shift_id': 'B'},
        // Shift B End Forming (FINAL) -> 500
        {'part_code': 'V21', 'machine_id': 'm-endforming-old', 'machine_name': 'End Forming', 'sequence_order': 3, 'good_qty': 500, 'shift_id': 'B'},
      ];

      final totals = calculatePartGoodTotals(records, testFlow, machines: testMachines);

      // Must be exactly 400 + 500 = 900!
      expect(totals, {'V21': 900});
    });
  });
}
