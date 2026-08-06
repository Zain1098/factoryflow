import 'package:factoryflow/core/providers/master_data_providers.dart';
import 'package:factoryflow/core/providers/production_flow_provider.dart';
import 'package:factoryflow/features/production/production_page.dart';
import 'package:factoryflow/features/production/production_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestProductionFlowNotifier extends ProductionFlowNotifier {
  @override
  ProductionFlowConfig build() => const ProductionFlowConfig();

  @override
  Future<void> ensureLoaded() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpProductionPage(
    WidgetTester tester, {
    required Future<List<Map<String, dynamic>>> Function() loadParts,
    double rawMaterialQty = 100,
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
          productionRawMaterialProvider.overrideWith(
            (ref, partId) async => rawMaterialQty,
          ),
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
    await tester.scrollUntilVisible(find.text('Add machine entry'), 250);
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
    await tester.scrollUntilVisible(find.text('Add machine entry'), 250);
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

  testWidgets('zero raw material is shown before machine entry',
      (tester) async {
    await pumpProductionPage(
      tester,
      rawMaterialQty: 0,
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

    expect(
      find.textContaining('No raw material is available for V21'),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(find.text('Add machine entry'), 250);
    final button = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Add machine entry'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(button.onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('added machine entry can be edited from the active page',
      (tester) async {
    await pumpProductionPage(
      tester,
      rawMaterialQty: 500,
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
    await tester.scrollUntilVisible(find.text('Add machine entry'), 250);
    await tester.tap(find.text('Add machine entry'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add Machine Entry to List'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Edit machine entry'), findsOneWidget);
    expect(find.byTooltip('Remove machine entry'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
