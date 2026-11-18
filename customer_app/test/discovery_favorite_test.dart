// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jain_client/jain_client.dart';
import 'package:jain_customer/discovery.dart';

class FavoriteApi extends Api {
  var saved = true;
  String? deleted;

  @override
  Future<Json> get(String path) async => {
    'id': 'candidate',
    'age': 29,
    'city': 'Pune',
    'favorite': saved,
  };

  @override
  Future<Json> delete(String path) async {
    deleted = path;
    saved = false;
    return {};
  }
}

void main() {
  testWidgets('detail shows the stored favorite even when opened from browse', (
    tester,
  ) async {
    final api = FavoriteApi();
    addTearDown(api.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Detail(api: api, id: 'candidate'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Remove favorite'), findsOneWidget);
    await tester.tap(find.text('Remove favorite'));
    await tester.pumpAndSettle();
    expect(api.deleted, '/favorites/candidate');
    expect(find.text('Add favorite'), findsOneWidget);
  });
}
