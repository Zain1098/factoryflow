const List<String> kBpRejectReasons = [
  'Dimensional Out of Tolerance',
  'Surface Defect',
  'Porosity / Crack',
  'Wrong Material',
  'Plating Defect',
  'Other',
];

const List<String> kApRejectReasons = [
  'Dimensional Out of Tolerance',
  'Surface Defect',
  'Plating Defect',
  'Porosity / Crack',
  'Wrong Part',
  'Other',
];

const List<String> kRtvReasons = [
  'Dimensional Out of Tolerance',
  'Surface Defect',
  'Plating Defect',
  'Porosity / Crack',
  'Wrong Material / Part',
  'Vendor Quality Issue',
  'Other',
];

class AppConstants {
  AppConstants._();

  static const String appName = 'FactoryFlow';
  // Version is read at runtime from pubspec via --dart-define or package_info.
  // Fallback keeps the build working without the plugin.
  static const String appVersion = String.fromEnvironment(
    'APP_VERSION',
    defaultValue: '1.0.0+1',
  );
  static const int syncEnvelopeSchemaVersion = 1;
  static const bool atomicProductionSyncEnabled = true;

  /// Must match the factory UUID in supabase_schema.sql seed data
  static const String defaultFactoryId = '00000000-0000-0000-0000-000000000001';
  static const int minTapTargetSize = 48;
  static const int sessionTimeoutMinutes = 30;
  static const int rtvMaxCycles = 3;
  static const int syncRetryMaxAttempts = 5;
  static const Duration syncRetryBaseDelay = Duration(seconds: 2);

  /// Batch format: {PartCode}-{YYYYMMDD}-{MachineSeq}-{Sequence}
  static String batchNumberPattern(
      String partCode, DateTime date, String machineSeq, int sequence,) {
    final dateStr = '${date.year}'
        '${date.month.toString().padLeft(2, '0')}'
        '${date.day.toString().padLeft(2, '0')}';
    return '$partCode-$dateStr-$machineSeq-${sequence.toString().padLeft(3, '0')}';
  }
}
