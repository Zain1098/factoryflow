import 'package:factoryflow/core/providers/production_flow_provider.dart';
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
}
