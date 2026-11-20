// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jain_client/jain_client.dart';

import 'package:jain_admin/main.dart';

class TestApi extends Api {
  TestApi({this.startsSignedIn = true});
  final bool startsSignedIn;
  bool rejectLogin = false;
  int changes = 0;

  @override
  Future<void> restore() async {
    if (startsSignedIn) account = const Account('admin-test', 'admin', '');
  }

  @override
  Future<void> signInAdmin(String password) async {
    if (rejectLogin) {
      throw const ApiError(401, 'The administrator password is incorrect.', {});
    }
    account = const Account('admin-test', 'admin', '');
    notifyListeners();
  }

  @override
  Future<void> changeAdminPassword(
    String current,
    String next,
    String confirmation,
  ) async {
    changes++;
    expire();
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
    expect(find.text('Login'), findsOneWidget);
  });

  testWidgets(
    'password-only login leads to Settings and changing the password signs out',
    (tester) async {
      final api = TestApi(startsSignedIn: false)..rejectLogin = true;
      addTearDown(api.dispose);
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(AdminApp(api: api));
      await tester.pumpAndSettle();
      final fields = find.byType(EditableText);
      expect(fields, findsOneWidget);
      expect(tester.widget<EditableText>(fields).obscureText, isTrue);
      expect(find.text('Email address'), findsNothing);
      final sample = List.filled(22, 'w').join();
      await tester.enterText(fields, sample);
      await tester.tap(find.text('Login'));
      await tester.pumpAndSettle();
      expect(
        find.text('The administrator password is incorrect.'),
        findsOneWidget,
      );
      api.rejectLogin = false;
      await tester.enterText(fields, sample);
      await tester.tap(find.text('Login'));
      await tester.pumpAndSettle();
      expect(find.text('Active customers'), findsOneWidget);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Settings'));
      await tester.pumpAndSettle();
      expect(fields, findsNWidgets(3));
      for (final field in tester.widgetList<EditableText>(fields)) {
        expect(field.obscureText, isTrue);
      }
      const next = 'x';
      await tester.enterText(fields.at(0), sample);
      await tester.enterText(fields.at(1), next);
      await tester.enterText(fields.at(2), sample);
      await tester.tap(find.widgetWithText(FilledButton, 'Change Password'));
      await tester.pumpAndSettle();
      expect(find.text('The new passwords do not match.'), findsOneWidget);
      expect(api.changes, 0);
      await tester.enterText(fields.at(2), next);
      await tester.tap(find.widgetWithText(FilledButton, 'Change Password'));
      await tester.pumpAndSettle();
      expect(api.changes, 1);
      expect(find.text('Login'), findsOneWidget);
    },
  );
}
