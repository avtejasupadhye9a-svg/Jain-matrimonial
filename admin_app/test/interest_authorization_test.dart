// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jain_client/jain_client.dart';
import 'package:jain_admin/review.dart';

class InterestQueueApi extends Api {
  var eligible = false;

  @override
  Future<Json> get(String path) async => {
    'items': [
      {
        'id': '7f000000-0000-4000-8000-000000000001',
        'sender': 'Sender',
        'recipient': 'Recipient',
        'status': 'pending_contact_authorization',
        'activeConsents': eligible ? 2 : 1,
        'canAuthorize': eligible ? 1 : 0,
        'version': 3,
      },
    ],
  };
}

void main() {
  testWidgets('authorization is available only when API eligibility allows it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1250, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = InterestQueueApi();
    addTearDown(api.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AdminQueue(api: api, queue: 'interests'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('authorize'), findsNothing);
    expect(
      find.text(
        'Authorization requires current consent from both parties and two eligible profiles.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    api.eligible = true;
    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('authorize'), findsOneWidget);
  });
}
