import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final batchConfigProvider = NotifierProvider<BatchConfigNotifier, bool>(BatchConfigNotifier.new);

class BatchConfigNotifier extends Notifier<bool> {
  static const _key = 'show_batch_number';

  @override
  bool build() {
    _load();
    return true; // default to true
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool(_key) ?? true;
  }

  Future<void> toggle(bool enabled) async {
    state = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, enabled);
  }
}
