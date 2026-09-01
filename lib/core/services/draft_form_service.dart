import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final draftFormServiceProvider = Provider<DraftFormService>((ref) {
  return DraftFormService();
});

class DraftFormService {
  static const String _prefix = 'ff_form_draft_';

  Future<void> saveDraft(String formKey, Map<String, dynamic> data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = '$_prefix$formKey';
      final payload = jsonEncode({
        'timestamp': DateTime.now().toIso8601String(),
        'data': data,
      });
      await prefs.setString(key, payload);
    } catch (_) {}
  }

  Future<Map<String, dynamic>?> loadDraft(String formKey) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = '$_prefix$formKey';
      final raw = prefs.getString(key);
      if (raw == null) return null;
      final parsed = jsonDecode(raw) as Map<String, dynamic>;
      final timestampStr = parsed['timestamp'] as String?;
      if (timestampStr != null) {
        final timestamp = DateTime.tryParse(timestampStr);
        if (timestamp != null &&
            DateTime.now().difference(timestamp).inHours > 24) {
          await clearDraft(formKey);
          return null;
        }
      }
      return parsed['data'] as Map<String, dynamic>?;
    } catch (_) {
      return null;
    }
  }

  Future<void> clearDraft(String formKey) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('$_prefix$formKey');
    } catch (_) {}
  }
}
