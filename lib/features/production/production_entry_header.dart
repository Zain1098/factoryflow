part of 'production_page.dart';

extension _ProductionEntryHeader on _ProductionScreenState {
  double _safeFormWidth(BuildContext context) =>
      (MediaQuery.sizeOf(context).width - 64).clamp(200.0, 560.0).toDouble();

  /// Shift selector — reads from DB shifts table, falls back to A/B/C.
  Widget _buildShiftSelector() {
    final shiftsAsync = ref.watch(shiftsProvider);
    final shifts = shiftsAsync.value ?? [];

    // If DB has configured shifts, use them as SegmentedButton segments.
    // Otherwise fall back to hardcoded A/B/C so the form is never broken.
    final segments = shifts.isNotEmpty
        ? shifts
            .map((s) => ButtonSegment<String>(
                  value: s['name'] as String,
                  label: Text('Shift ${s['name']}'),
                ),)
            .toList()
        : const [
            ButtonSegment(value: 'A', label: Text('Shift A')),
            ButtonSegment(value: 'B', label: Text('Shift B')),
            ButtonSegment(value: 'C', label: Text('Shift C')),
          ];

    // If current _shiftId is not in the available segments, reset to first.
    final validIds = segments.map((s) => s.value).toSet();
    final effectiveShift = validIds.contains(_shiftId)
        ? _shiftId
        : (validIds.isNotEmpty ? validIds.first : 'A');

    return SizedBox(
      width: _safeFormWidth(context),
      child: SegmentedButton<String>(
        showSelectedIcon: false,
        segments: segments,
        selected: {effectiveShift},
        onSelectionChanged: (value) => _setShift(value.first),
      ),
    );
  }

  Widget _buildPartSelector(List<Map<String, dynamic>> parts) => SizedBox(
        width: _safeFormWidth(context),
        child: DropdownButton<String>(
          isExpanded: true,
          value: _partId,
          hint: const Text('Select a finished part'),
          items: parts
              .map((part) => DropdownMenuItem<String>(
                    value: part['id'] as String,
                    child: Text('${part['code']} – ${part['name']}'),
                  ),)
              .toList(),
          onChanged: (value) => _onPartChanged(value, parts),
        ),
      );
}
