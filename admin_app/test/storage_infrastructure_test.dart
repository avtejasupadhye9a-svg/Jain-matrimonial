import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jain_admin/storage_infrastructure.dart';
import 'package:jain_client/jain_client.dart';

class InfrastructureApi extends Api {
  bool available = true;

  @override
  Future<Json> get(String path) async {
    if (path != '/admin/infrastructure') throw StateError('Unexpected route');

    if (!available) throw const ApiError(503, 'Management unavailable', {});
    return {
      'generation': 1,
      'machine': 'Designated storage fixture',
      'origin': 'fixture-primary',
      'health': {'freeBytes': 1048576},
      'pending': 2,
    };
  }
}

class AbsentInstallationFile extends Fake implements File {
  @override
  Future<bool> exists() async => false;
}

void main() {
  testWidgets('storage status clears verified indicators on a failed refresh', (
    tester,
  ) async {
    final api = InfrastructureApi();
    addTearDown(api.dispose);
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await IOOverrides.runZoned(() async {
      await tester.pumpWidget(
        MaterialApp(home: StorageInfrastructure(api: api)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Designated storage fixture'), findsOneWidget);
      expect(find.text('Verified'), findsOneWidget);
      api.available = false;
      await tester.tap(find.byTooltip('Refresh'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Storage management unavailable'),
        findsOneWidget,
      );
      expect(find.text('Unverified'), findsOneWidget);
      expect(find.text('Designated storage fixture'), findsNothing);
    }, createFile: (_) => AbsentInstallationFile());
    await tester.pumpWidget(const SizedBox());
  });
}
