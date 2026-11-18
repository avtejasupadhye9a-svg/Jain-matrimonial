// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jain_client/jain_client.dart';

import 'package:jain_admin/main.dart';

class TestApi extends Api {
  @override
  Future<Json> get(String path) async {
    if (path == '/admin/dashboard') {
      return {
        'accounts': 4,
        'revisions': 2,
        'claims': 0,
        'reports': 0,
        'privacyRequests': 0,
        'interests': 1,
      };
    }
    if (path == '/readiness') return {'status': 'ok', 'emailConfigured': false};
    return {'items': <Json>[]};
  }
}

void main() {
  testWidgets('admin dashboard routes to review and storage queues', (
    tester,
  ) async {
    final api = TestApi();
    addTearDown(api.dispose);
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: AdminHome(api: api)));
    await tester.pumpAndSettle();
    expect(find.text('Active customers'), findsOneWidget);
    await tester.tap(find.text('Profile reviews').first);
    await tester.pumpAndSettle();
    expect(find.text('There are no records to display.'), findsOneWidget);
    await tester.ensureVisible(find.text('Storage and readiness'));
    await tester.tap(find.text('Storage and readiness'));
    await tester.pumpAndSettle();
    expect(find.text('File transfer unavailable'), findsOneWidget);
  });
}
