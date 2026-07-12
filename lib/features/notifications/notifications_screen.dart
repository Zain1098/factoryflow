import 'package:flutter/material.dart';

import '../../core/widgets/shared_widgets.dart';

class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: const EmptyState(
        message: 'No notifications yet.\n\nAlerts for target misses, machine breakdowns, RTV pending, and low stock will appear here.',
        icon: Icons.notifications_none_outlined,
      ),
    );
  }
}
