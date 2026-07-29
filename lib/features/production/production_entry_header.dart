part of 'production_page.dart';

extension _ProductionEntryHeader on _ProductionScreenState {
  double _safeFormWidth(BuildContext context) =>
      (MediaQuery.sizeOf(context).width - 64).clamp(200.0, 560.0).toDouble();

  Widget _buildShiftSelector() => SizedBox(
        width: _safeFormWidth(context),
        child: SegmentedButton<String>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 'A', label: Text('Shift A')),
            ButtonSegment(value: 'B', label: Text('Shift B')),
            ButtonSegment(value: 'C', label: Text('Shift C')),
          ],
          selected: {_shiftId},
          onSelectionChanged: (value) => _setShift(value.first),
        ),
      );

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
                  ))
              .toList(),
          onChanged: (value) => _onPartChanged(value, parts),
        ),
      );
}
