import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../features/auth/auth_providers.dart';
import '../providers/master_data_providers.dart';
import 'barcode_scanner_view.dart';

/// Compact reusable header for top-level operational screens.
class CompactScreenHeader extends StatelessWidget {
  const CompactScreenHeader({
    super.key,
    required this.eyebrow,
    required this.title,
    this.trailing,
  });

  final String eyebrow;
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  eyebrow.toUpperCase(),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    letterSpacing: 1.1,
                  ),
                ),
                const SizedBox(height: 3),
                Text(title, style: theme.textTheme.headlineSmall),
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class SoftActionTile extends StatelessWidget {
  const SoftActionTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .surface
                      .withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon, color: color, size: 18),
              ),
              const SizedBox(height: 4),
              Text(
                title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(fontSize: 13),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Text('Open', style: Theme.of(context).textTheme.labelMedium?.copyWith(fontSize: 11)),
                  const Spacer(),
                  const Icon(Icons.arrow_forward_rounded, size: 14),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── App Form Field ───────────────────────────────────────────────────────────
class AppFormField extends StatelessWidget {
  const AppFormField({
    super.key,
    required this.label,
    this.controller,
    this.keyboardType = TextInputType.text,
    this.inputFormatters,
    this.validator,
    this.onChanged,
    this.readOnly = false,
    this.maxLines = 1,
    this.hint,
    this.prefixIcon,
    this.suffixIcon,
    this.initialValue,
    this.autofocus = false,
  });

  final String label;
  final TextEditingController? controller;
  final TextInputType keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final String? Function(String?)? validator;
  final void Function(String)? onChanged;
  final bool readOnly;
  final int maxLines;
  final String? hint;
  final Widget? prefixIcon;
  final Widget? suffixIcon;
  final String? initialValue;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      initialValue: initialValue,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      validator: validator,
      onChanged: onChanged,
      readOnly: readOnly,
      maxLines: maxLines,
      autofocus: autofocus,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: prefixIcon,
        suffixIcon: suffixIcon,
        alignLabelWithHint: maxLines > 1,
      ),
    );
  }
}

// ─── Number Form Field ────────────────────────────────────────────────────────
class NumberFormField extends StatelessWidget {
  const NumberFormField({
    super.key,
    required this.label,
    required this.controller,
    this.validator,
    this.onChanged,
    this.hint,
    this.allowDecimal = true,
    this.prefixIcon,
    this.readOnly = false,
  });

  final String label;
  final TextEditingController controller;
  final String? Function(String?)? validator;
  final void Function(String)? onChanged;
  final String? hint;
  final bool allowDecimal;
  final Widget? prefixIcon;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      readOnly: readOnly,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [
        FilteringTextInputFormatter.allow(
          allowDecimal ? RegExp(r'^\d*\.?\d*') : RegExp(r'^\d*'),
        ),
      ],
      validator: validator,
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint ?? '0',
        prefixIcon: prefixIcon ?? const Icon(Icons.numbers),
      ),
    );
  }
}

// ─── App Dropdown ─────────────────────────────────────────────────────────────
class AppDropdown<T> extends StatelessWidget {
  const AppDropdown({
    super.key,
    required this.label,
    required this.items,
    required this.value,
    required this.onChanged,
    this.validator,
    this.hint,
    this.prefixIcon,
    this.isRequired = false,
  });

  final String label;
  final List<DropdownMenuItem<T>> items;
  final T? value;
  final void Function(T?)? onChanged;
  final String? Function(T?)? validator;
  final String? hint;
  final Widget? prefixIcon;
  final bool isRequired;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<T>(
      isExpanded: true,
      initialValue: value,
      items: items,
      onChanged: onChanged,
      validator: validator ??
          (isRequired ? (v) => v == null ? 'Required' : null : null),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint ?? 'Select $label',
        prefixIcon: prefixIcon,
      ),
    );
  }
}

// ─── Section Header ───────────────────────────────────────────────────────────
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key});
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 10),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 20,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary,
              borderRadius: BorderRadius.circular(99),
            ),
          ),
          const SizedBox(width: 9),
          Text(
            title.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.05,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Divider(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}

/// Consistent elevated surface for entry-only information such as dates,
/// quick summaries, and selected stock. It deliberately owns no state, so it
/// can be adopted across entry screens without changing their workflows.
class EntryInfoSurface extends StatelessWidget {
  const EntryInfoSurface({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: padding ?? const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.8),
        ),
        boxShadow: [
          BoxShadow(
            color: theme.shadowColor.withValues(
              alpha: theme.brightness == Brightness.dark ? 0.08 : 0.025,
            ),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }
}

/// Standard scrolling shell for operational forms. The animated bottom inset
/// keeps the active field and save area reachable when the mobile keyboard is
/// visible, while preserving each screen's existing form state and callbacks.
class EntryFormScroll extends StatelessWidget {
  const EntryFormScroll({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: padding.add(const EdgeInsets.only(bottom: 112)),
        child: child,
      ),
    );
  }
}

// ─── Stock Card ───────────────────────────────────────────────────────────────
class StockCard extends StatelessWidget {
  const StockCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.color,
    this.subtitle,
    this.onTap,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color? color;
  final String? subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cardColor = color ?? theme.colorScheme.primary;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: cardColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Icon(icon, color: cardColor, size: 16),
                  ),
                  const Spacer(),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontSize: 10,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                value,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: cardColor,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontSize: 11,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── KPI Tile ─────────────────────────────────────────────────────────────────
class KpiTile extends StatelessWidget {
  const KpiTile({
    super.key,
    required this.label,
    required this.value,
    this.icon,
    this.color,
    this.isAlert = false,
  });

  final String label;
  final String value;
  final IconData? icon;
  final Color? color;
  final bool isAlert;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effectiveColor = isAlert
        ? theme.colorScheme.error
        : (color ?? theme.colorScheme.secondary);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: effectiveColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: effectiveColor.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, color: effectiveColor, size: 20),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: effectiveColor,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Sync Status Badge ────────────────────────────────────────────────────────
class SyncBadge extends StatelessWidget {
  const SyncBadge({super.key, required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    if (count == 0) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.orange,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '$count pending sync',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// ─── Save Button ──────────────────────────────────────────────────────────────
class SaveButton extends StatelessWidget {
  const SaveButton({
    super.key,
    required this.onPressed,
    this.isLoading = false,
    this.label = 'Save Entry',
  });

  final VoidCallback? onPressed;
  final bool isLoading;
  final String label;

  @override
  Widget build(BuildContext context) {
    return EntryInfoSurface(
      padding: const EdgeInsets.all(6),
      child: FilledButton.icon(
        onPressed: isLoading ? null : onPressed,
        icon: isLoading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Icon(Icons.save_outlined),
        label: Text(label),
      ),
    );
  }
}

// ─── Error Banner ─────────────────────────────────────────────────────────────
String userFacingError(String message) {
  final normalized = message.replaceFirst(RegExp(r'^Exception:\s*'), '');
  if (normalized.contains('PostgrestException') ||
      normalized.contains('SocketException') ||
      normalized.contains('Failed host lookup') ||
      normalized.contains('TimeoutException')) {
    return 'Could not complete this request. Check your connection and try again.';
  }
  if (normalized.startsWith('Error:')) {
    return 'Could not load this section. Please try again.';
  }
  return normalized.length > 180
      ? '${normalized.substring(0, 177)}…'
      : normalized;
}

class ErrorBanner extends StatelessWidget {
  const ErrorBanner(this.message, {super.key});
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: theme.colorScheme.error.withValues(alpha: 0.25),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.error_outline,
            color: theme.colorScheme.onErrorContainer,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              userFacingError(message),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Success Banner ───────────────────────────────────────────────────────────
class SuccessBanner extends StatelessWidget {
  const SuccessBanner(this.message, {super.key});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        color: Colors.green.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.check_circle_outline, color: Colors.green, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: Colors.green,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Empty State ─────────────────────────────────────────────────────────────
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.message, this.icon, this.action});
  final String message;
  final IconData? icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon ?? Icons.inbox_outlined,
              size: 64,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (action != null) ...[const SizedBox(height: 24), action!],
          ],
        ),
      ),
    );
  }
}

// ─── Confirm Dialog ───────────────────────────────────────────────────────────
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  bool isDestructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: isDestructive
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error,
                )
              : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

// ─── Record Date/Time Picker ──────────────────────────────────────────────────
/// Shows current date+time by default. Tap the edit icon to set a custom
/// date/time (e.g. for backdated entries). Pass [showTime] = false for
/// screens that only need a date (e.g. machine downtime).
class RecordDateTimePicker extends StatelessWidget {
  const RecordDateTimePicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.showTime = true,
  });

  final DateTime value;
  final ValueChanged<DateTime> onChanged;
  final bool showTime;

  Future<void> _pick(BuildContext context) async {
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: value,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (pickedDate == null || !context.mounted) return;

    if (!showTime) {
      final d = DateTime(
        pickedDate.year,
        pickedDate.month,
        pickedDate.day,
        value.hour,
        value.minute,
      );
      onChanged(d);
      return;
    }

    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: value.hour, minute: value.minute),
    );
    if (pickedTime == null) return;
    final dt = DateTime(
      pickedDate.year,
      pickedDate.month,
      pickedDate.day,
      pickedTime.hour,
      pickedTime.minute,
    );
    onChanged(dt);
  }

  @override
  Widget build(BuildContext context) {
    final isCustom = !_isSameMinute(value, DateTime.now());
    final label = showTime
        ? DateFormat('dd MMM yyyy, hh:mm a').format(value)
        : DateFormat('dd MMM yyyy').format(value);

    final theme = Theme.of(context);
    return EntryInfoSurface(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      // This control appears inside scroll views and bottom sheets. A Row with
      // an Expanded label fails if an ancestor is measuring at intrinsic width,
      // producing "BoxConstraints forces an infinite width" and a blank page.
      // Wrap has no flex child, so it stays safe on every screen size.
      child: LayoutBuilder(
        builder: (context, constraints) {
          final labelMaxWidth = constraints.hasBoundedWidth
              ? (constraints.maxWidth - 120).clamp(120.0, 260.0).toDouble()
              : 240.0;

          return Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                      color: (isCustom
                              ? Colors.orange
                              : theme.colorScheme.primary)
                          .withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      showTime ? Icons.access_time : Icons.calendar_today,
                      size: 17,
                      color: isCustom
                          ? Colors.orange.shade800
                          : theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: labelMaxWidth),
                    child: Text(label, overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
              if (isCustom)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'Custom',
                    style: TextStyle(color: Colors.orange, fontSize: 11),
                  ),
                )
              else
                const Text(
                  'Auto',
                  style: TextStyle(color: Colors.green, fontSize: 12),
                ),
              InkResponse(
                onTap: () => _pick(context),
                radius: 22,
                child: Icon(
                  Icons.edit_calendar_outlined,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  bool _isSameMinute(DateTime a, DateTime b) =>
      a.year == b.year &&
      a.month == b.month &&
      a.day == b.day &&
      a.hour == b.hour &&
      a.minute == b.minute;
}

// ─── Live Stock Balance Chip ──────────────────────────────────────────────────
class LiveStockChip extends StatelessWidget {
  const LiveStockChip({
    super.key,
    required this.stock,
    this.unit = 'PCS',
    this.stageName,
    this.isLoading = false,
  });

  final double? stock;
  final String unit;
  final String? stageName;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final val = stock ?? 0;
    final isZero = val <= 0;
    final bg = isZero
        ? Colors.orange.withValues(alpha: 0.12)
        : theme.colorScheme.primaryContainer.withValues(alpha: 0.4);
    final fg = isZero
        ? Colors.orange.shade800
        : theme.colorScheme.onPrimaryContainer;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isZero ? Colors.orange.withValues(alpha: 0.4) : Colors.transparent,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isZero ? Icons.warning_amber_outlined : Icons.inventory_2_outlined,
            size: 16,
            color: fg,
          ),
          const SizedBox(width: 8),
          if (isLoading)
            const SizedBox.square(
              dimension: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Text(
              '${stageName != null ? '$stageName: ' : ''}Available ${val.toInt()} $unit',
              style: TextStyle(
                color: fg,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Industrial Quantity Stepper Buttons ──────────────────────────────────────
class QuantityStepper extends StatelessWidget {
  const QuantityStepper({
    super.key,
    required this.controller,
    this.onChanged,
    this.steppers = const [10, 50, 100],
  });

  final TextEditingController controller;
  final ValueChanged<String>? onChanged;
  final List<int> steppers;

  void _add(int amount) {
    final current = double.tryParse(controller.text) ?? 0;
    final updated = (current + amount).clamp(0, 9999999).toInt();
    controller.text = updated.toString();
    if (onChanged != null) onChanged!(controller.text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ActionChip(
              avatar: const Icon(Icons.clear, size: 14),
              label: const Text('Clear'),
              onPressed: () {
                controller.clear();
                if (onChanged != null) onChanged!('');
              },
            ),
          ),
          for (final step in steppers)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ActionChip(
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
                avatar: const Icon(Icons.add, size: 14),
                label: Text('+$step'),
                onPressed: () => _add(step),
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Sticky Bottom Action Bar ─────────────────────────────────────────────────
class StickyBottomActionBar extends StatelessWidget {
  const StickyBottomActionBar({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 8,
            offset: const Offset(0, -3),
          ),
        ],
      ),
      child: SafeArea(top: false, child: child),
    );
  }
}

// ─── Draft Recovery Banner ────────────────────────────────────────────────────
class DraftRecoveryBanner extends StatelessWidget {
  const DraftRecoveryBanner({
    super.key,
    required this.onRestore,
    required this.onDiscard,
  });

  final VoidCallback onRestore;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.edit_note, color: theme.colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Unsubmitted draft restored',
              style: TextStyle(
                color: theme.colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton(
            onPressed: onDiscard,
            child: const Text('Discard'),
          ),
          FilledButton.tonal(
            onPressed: onRestore,
            child: const Text('Keep'),
          ),
        ],
      ),
    );
  }
}

// ─── Skeleton Shimmer Loader ──────────────────────────────────────────────────

class SkeletonShimmerLoader extends StatefulWidget {
  const SkeletonShimmerLoader({
    super.key,
    this.height = 16,
    this.width = double.infinity,
    this.borderRadius = 8,
  });

  final double height;
  final double width;
  final double borderRadius;

  @override
  State<SkeletonShimmerLoader> createState() => _SkeletonShimmerLoaderState();
}

class _SkeletonShimmerLoaderState extends State<SkeletonShimmerLoader>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _anim = Tween<double>(begin: 0.3, end: 0.85).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final baseColor = isDark ? Colors.grey[800]! : Colors.grey[300]!;

    return AnimatedBuilder(
      animation: _anim,
      builder: (context, _) {
        return Container(
          height: widget.height,
          width: widget.width,
          decoration: BoxDecoration(
            color: baseColor.withValues(alpha: _anim.value),
            borderRadius: BorderRadius.circular(widget.borderRadius),
          ),
        );
      },
    );
  }
}

// ─── Role Filtered View ───────────────────────────────────────────────────────

class RoleFilteredView extends ConsumerWidget {
  const RoleFilteredView({
    super.key,
    required this.allowedRoles,
    required this.child,
    this.fallback = const SizedBox.shrink(),
  });

  final List<String> allowedRoles;
  final Widget child;
  final Widget fallback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final role = ref.watch(userRoleProvider);
    final userRoleName = role?.value.toLowerCase() ?? 'operator';
    if (allowedRoles.any((r) => r.toLowerCase() == userRoleName)) {
      return child;
    }
    return fallback;
  }
}

// ─── Global Quick Search Sheet ────────────────────────────────────────────────

class GlobalQuickSearchSheet extends ConsumerStatefulWidget {
  const GlobalQuickSearchSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const GlobalQuickSearchSheet(),
    );
  }

  @override
  ConsumerState<GlobalQuickSearchSheet> createState() =>
      _GlobalQuickSearchSheetState();
}

class _GlobalQuickSearchSheetState
    extends ConsumerState<GlobalQuickSearchSheet> {
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      height: MediaQuery.of(context).size.height * 0.75,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.search, size: 24),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Global Batch & Stock Lookup',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _searchCtrl,
            autofocus: true,
            decoration: InputDecoration(
              hintText: 'Search Batch #, Part Code, or PO...',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(
                icon: const Icon(Icons.qr_code_scanner),
                onPressed: () async {
                  final code = await BarcodeScannerView.scan(
                    context,
                    title: 'Scan Barcode',
                  );
                  if (code != null && code.isNotEmpty) {
                    _searchCtrl.text = code;
                    setState(() => _query = code.toLowerCase());
                  }
                },
              ),
            ),
            onChanged: (q) => setState(() => _query = q.toLowerCase()),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _query.trim().isEmpty
                ? const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.qr_code_2, size: 48, color: Colors.grey),
                        SizedBox(height: 8),
                        Text(
                          'Scan or type a batch code / part number above.',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ],
                    ),
                  )
                : _buildSearchResults(),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchResults() {
    final partsAsync = ref.watch(partsProvider);
    return partsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error searching: $e')),
      data: (parts) {
        final matches = parts.where((p) {
          final code = (p['code'] as String? ?? '').toLowerCase();
          final name = (p['name'] as String? ?? '').toLowerCase();
          return code.contains(_query) || name.contains(_query);
        }).toList();

        if (matches.isEmpty) {
          return Center(
            child: Text(
              'No parts or batches match "$_query"',
              style: const TextStyle(color: Colors.grey),
            ),
          );
        }

        return ListView.separated(
          itemCount: matches.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final part = matches[i];
            return ListTile(
              leading: const CircleAvatar(
                child: Icon(Icons.inventory_2_outlined, size: 18),
              ),
              title: Text('${part['code']} – ${part['name']}'),
              subtitle: Text('ID: ${part['id']}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.pop(context);
              },
            );
          },
        );
      },
    );
  }
}

