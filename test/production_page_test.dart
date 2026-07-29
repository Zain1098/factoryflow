import 'package:factoryflow/core/providers/master_data_providers.dart';
import 'package:factoryflow/core/providers/production_flow_provider.dart';
import 'package:factoryflow/features/production/production_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestProductionFlowNotifier extends ProductionFlowNotifier {
  @override
  ProductionFlowConfig build() => const ProductionFlowConfig();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpProductionPage(
    WidgetTester tester, {
    required Future<List<Map<String, dynamic>>> Function() loadParts,
  }) async {
    tester.view
      ..physicalSize = const Size(360, 640)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          partsProvider.overrideWith((ref) => loadParts()),
          machinesProvider.overrideWith(
            (ref) async => [
              {
                'id': 'machine-bending',
                'name': 'Bending',
                'machine_code': 'B',
                'sequence_order': 1,
                'active': 1,
              },
            ],
          ),
          operatorsProvider.overrideWith(
            (ref) async => [
              {
                'id': 'operator-a',
                'name': 'Operator A',
                'active': 1,
              },
            ],
          ),
          productionFlowProvider.overrideWith(_TestProductionFlowNotifier.new),
        ],
        child: const MaterialApp(home: ProductionScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Daily Production renders on a narrow mobile screen', (
    tester,
  ) async {
    await pumpProductionPage(
      tester,
      loadParts: () async => [
        {
          'id': 'part-v21',
          'code': 'V21',
          'name': 'Valve Part',
          'uom': 'PCS',
          'active': 1,
        },
      ],
    );

    expect(find.text('Daily Production'), findsOneWidget);
    expect(find.text('Production details'), findsOneWidget);
    expect(find.text('Select finished part'), findsOneWidget);
    expect(find.text('Machine entries'), findsOneWidget);
    expect(find.text('Add machine entry'), findsOneWidget);
    expect(find.text('Save production job'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('machine form opens after selecting a part', (tester) async {
    await pumpProductionPage(
      tester,
      loadParts: () async => [
        {
          'id': 'part-v21',
          'code': 'V21',
          'name': 'Valve Part',
          'uom': 'PCS',
          'active': 1,
        },
      ],
    );

    await tester.tap(find.text('Select finished part'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('V21'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add machine entry'));
    await tester.pumpAndSettle();

    expect(find.text('Add Machine Entry'), findsOneWidget);
    expect(find.text('Bending'), findsWidgets);
    expect(find.text('Operator A'), findsWidgets);
    expect(
      find.text('Master data is still loading. Please try again.'),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('part loading failure is visible instead of a blank page', (
    tester,
  ) async {
    await pumpProductionPage(
      tester,
      loadParts: () => Future.error(StateError('local database unavailable')),
    );

    expect(find.text('Daily Production'), findsOneWidget);
    expect(find.textContaining('Parts could not load:'), findsOneWidget);
    expect(find.textContaining('local database unavailable'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
