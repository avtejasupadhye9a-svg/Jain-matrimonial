// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jain_client/jain_client.dart';

import 'package:jain_admin/main.dart';

class TestApi extends Api {
  @override
  Future<void> restore() async {
    account = const Account('admin-test', 'admin', 'admin@example.test');
  }

  void expire() {
    account = null;
    notifyListeners();
  }

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
    if (path.startsWith('/admin/profiles?')) {
      return {
        'items': [
          {'id': 'profile-test', 'name': 'Synthetic candidate'},
        ],
      };
    }
    if (path == '/profiles/profile-test') {
      return {
        'data': {'name': 'Synthetic candidate'},
        'history': [],
      };
    }
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
    expect(find.text('File transfer disabled'), findsOneWidget);
  });

  testWidgets('session expiration closes open private admin views', (
    tester,
  ) async {
    final api = TestApi();
    addTearDown(api.dispose);
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(AdminApp(api: api));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Profiles'));
    await tester.pumpAndSettle();
    expect(find.text('Synthetic candidate'), findsOneWidget);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Private documents'));
    await tester.pumpAndSettle();
    expect(
      find.text('Identity documents · administrator access'),
      findsOneWidget,
    );
    api.expire();
    await tester.pumpAndSettle();
    expect(find.text('Private documents'), findsNothing);
    expect(find.text('Email a verification code'), findsOneWidget);
  });
}
