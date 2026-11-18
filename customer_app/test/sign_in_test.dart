// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jain_client/jain_client.dart';

void main() {
  testWidgets('customer sign-in validates an empty email', (tester) async {
    final api = Api();
    addTearDown(api.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: SignIn(api: api, role: 'customer'),
      ),
    );
    expect(find.text('Sign in or create your account'), findsOneWidget);
    await tester.tap(find.text('Email a verification code'));
    await tester.pump();
    expect(find.text('Enter your email address'), findsOneWidget);
  });

  testWidgets('profile draft exposes a separate partner preference section', (
    tester,
  ) async {
    final api = Api();
    addTearDown(api.dispose);
    await tester.pumpWidget(MaterialApp(home: ProfileEditor(api: api)));
    for (var i = 0; i < 4; i++) {
      final next = find.text('Next section');
      await tester.scrollUntilVisible(
        next,
        250,
        scrollable: find
            .byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            )
            .first,
      );
      await tester.tap(next);
      await tester.pump();
    }
    expect(find.text('Partner preferences'), findsOneWidget);
    expect(find.text('Minimum age'), findsOneWidget);
  });
}
