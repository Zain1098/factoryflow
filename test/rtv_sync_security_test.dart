import 'package:flutter_test/flutter_test.dart';
import 'package:factoryflow/core/network/sync_service.dart';

void main() {
  test('normal RTV updates use the server-derived status RPC', () {
    for (final status in const [
      'partially_received',
      'approved',
      'rejected_again',
      'escalated',
    ]) {
      expect(rtvUpdateRpcName(status), 'refresh_rtv_status');
    }
  });

  test('Admin RTV resolutions use the restricted resolution RPC', () {
    expect(
      rtvUpdateRpcName('scrapped'),
      'resolve_rtv_escalation',
    );
    expect(
      rtvUpdateRpcName('force_dispatched'),
      'resolve_rtv_escalation',
    );
  });
}
