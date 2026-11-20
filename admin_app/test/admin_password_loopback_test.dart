// ignore_for_file: deprecated_member_use
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jain_admin/main.dart';
import 'package:jain_client/jain_client.dart';

class _LoopbackBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

Future<void> _waitFor(WidgetTester tester, Finder element) async {
  final elapsed = Stopwatch()..start();
  while (element.evaluate().isEmpty &&
      elapsed.elapsed < const Duration(seconds: 12)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump();
  }
  expect(element, findsOneWidget);
}

void main() {
  final original = Platform.environment['JAIN_TEST_ADMIN_PASSWORD'];
  final base = Platform.environment['JAIN_TEST_API_URL'];
  final enabled = original != null && base != null;
  if (enabled) _LoopbackBinding();

  testWidgets(
    'real Admin UI changes the local password and revokes other sessions',
    (tester) async {
      final initialPassword = original!;
      final api = Api(base: base!, persistSession: false);
      final secondDevice = Api(base: base, persistSession: false);
      addTearDown(api.dispose);
      addTearDown(secondDevice.dispose);
      expect(
        api.localDebug,
        isTrue,
        reason: 'A loopback test Worker is required',
      );
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final random = Random.secure();
      final replacement = String.fromCharCode(65 + random.nextInt(26));
      await tester.runAsync(() => secondDevice.signInAdmin(initialPassword));
      expect(secondDevice.account?.role, 'admin');
      await tester.pumpWidget(AdminApp(api: api));
      final loginButton = find.widgetWithText(FilledButton, 'Login');
      final fields = find.byType(EditableText);
      await _waitFor(tester, loginButton);
      expect(fields, findsOneWidget);
      await tester.enterText(fields, initialPassword);
      await tester.tap(loginButton);
      await _waitFor(tester, find.text('Active customers'));
      final dashboard = await tester.runAsync(
        () => secondDevice.get('/admin/dashboard'),
      );
      expect(dashboard, contains('accounts'));
      expect(api.account?.id, secondDevice.account?.id);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Settings'));
      await tester.pumpAndSettle();
      expect(fields, findsNWidgets(3));
      await tester.enterText(fields.at(0), initialPassword);
      await tester.enterText(fields.at(1), replacement);
      await tester.enterText(fields.at(2), replacement);
      await tester.tap(find.widgetWithText(FilledButton, 'Change Password'));
      await tester.pump();
      await _waitFor(tester, loginButton);

      final previousStatus = await tester.runAsync(() async {
        try {
          await secondDevice.get('/admin/dashboard');
        } on ApiError catch (error) {
          return error.status;
        }
        return 200;
      });
      expect(previousStatus, 401);
      await tester.enterText(fields, initialPassword);
      await tester.tap(loginButton);
      await tester.pump();
      await _waitFor(
        tester,
        find.text('The administrator password is incorrect.'),
      );
      await tester.enterText(fields, replacement);
      await tester.tap(loginButton);
      await tester.pump();
      await _waitFor(tester, find.text('Active customers'));
      await tester.tap(find.byTooltip('Sign out'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm'));
      await tester.pump();
      await _waitFor(tester, loginButton);
      expect(
        find.text('The service could not be reached. Try again.'),
        findsNothing,
      );
    },
    skip: !enabled,
  );
}
