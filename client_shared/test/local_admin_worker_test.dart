import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jain_client/jain_client.dart';

void main() {
  final password = Platform.environment['JAIN_TEST_ADMIN_PASSWORD'];
  final base =
      Platform.environment['JAIN_TEST_API_URL'] ?? 'http://127.0.0.1:8787';

  test(
    'Admin client signs in and publishes a profile through local Worker and D1',
    () async {
      final admin = Api(base: base, persistSession: false);
      addTearDown(admin.dispose);
      expect(admin.localDebug, isTrue);
      final suffix = DateTime.now().microsecondsSinceEpoch;
      await admin.signInAdmin(password!);
      expect(admin.account?.role, 'admin');
      expect(admin.account?.email, isEmpty);
      expect(await admin.get('/admin/dashboard'), contains('accounts'));
      final draft = await admin.post('/admin/profiles', {
        'consent': true,
        'claimEmail': 'claim-$suffix@example.test',
        'consentEvidence': 'Synthetic signed consent for the fixture',
        'data': {
          'name': 'Synthetic Admin flow',
          'dob': '1994-04-09',
          'gender': 'woman',
          'city': 'Pune',
          'country': 'India',
          'tradition': 'Digambara',
        },
      });
      final id = draft['id'] as String;
      final revision = await admin.post('/profiles/$id/submit', {
        'version': draft['version'],
      });
      await admin.post('/admin/revisions/${revision['id']}/decision', {
        'decision': 'approved',
      });
      expect((await admin.get('/profiles/$id'))['publishedId'], revision['id']);
      expect(items(await admin.get('/admin/profiles/$id/documents')), isEmpty);
      expect((await admin.get('/readiness'))['uploads'], 'disabled');

      final restored = Api(base: base, persistSession: false);
      addTearDown(restored.dispose);
      await restored.restore();
      expect(restored.account, isNull);
      await admin.logout();
      await expectLater(
        admin.get('/admin/dashboard'),
        throwsA(isA<ApiError>().having((e) => e.status, 'status', 401)),
      );
      expect(admin.account, isNull);
    },
    skip: password == null
        ? 'Provision an isolated local Admin and set JAIN_TEST_ADMIN_PASSWORD.'
        : false,
  );
}
