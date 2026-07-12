import 'package:equatable/equatable.dart';

import '../constants/stock_stages.dart';

class StockBalance extends Equatable {
  const StockBalance({
    required this.partId,
    required this.partName,
    required this.stage,
    required this.quantity,
  });

  final String partId;
  final String partName;
  final StockStage stage;
  final double quantity;

  @override
  List<Object?> get props => [partId, partName, stage, quantity];
}

class DashboardKpi extends Equatable {
  const DashboardKpi({
    required this.label,
    required this.value,
    this.unit,
    this.trend,
    this.isAlert = false,
  });

  final String label;
  final String value;
  final String? unit;
  final double? trend;
  final bool isAlert;

  @override
  List<Object?> get props => [label, value, unit, trend, isAlert];
}
