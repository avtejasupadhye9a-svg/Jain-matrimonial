import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jain_client/jain_client.dart';

void main() {
  final fixture = Platform.environment['JAIN_TEST_FIXTURE_KEY'];
  final base =
      Platform.environment['JAIN_TEST_API_URL'] ?? 'http://127.0.0.1:8787';

  test(
    'Admin client signs in and publishes a profile through local Worker and D1',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final admin = Api(base: base, sessionScope: 'admin-test')
        ..fixtureKey = fixture!;
      final bootstrap = HttpClient();
      addTearDown(admin.dispose);
      addTearDown(() => bootstrap.close(force: true));
      expect(admin.localDebug, isTrue);
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final email = 'admin-$suffix@example.test';
      final provision = await bootstrap.postUrl(
        Uri.parse(base).resolve('/_local/admin'),
      );
      provision.headers.contentType = ContentType.json;
      provision.headers.set('X-Local-Fixture-Key', fixture!);
      provision.write(jsonEncode({'email': email}));
      final response = await provision.close();
      expect(response.statusCode, 201);
      await response.drain<void>();

      final otp = await admin.requestCode(email);
      await admin.signIn(
        otp['challengeId'] as String,
        otp['localTestCode'] as String,
        'admin',
      );
      expect(admin.account?.role, 'admin');
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

      final restored = Api(base: base, sessionScope: 'admin-test')
        ..fixtureKey = fixture;
      addTearDown(restored.dispose);
      await restored.restore();
      expect(restored.account?.email, email);
      await restored.logout();
      await expectLater(
        admin.get('/admin/dashboard'),
        throwsA(isA<ApiError>().having((e) => e.status, 'status', 401)),
      );
      expect(admin.account, isNull);
    },
    skip: fixture == null
        ? 'Start a local fixture Worker and set JAIN_TEST_FIXTURE_KEY.'
        : false,
  );
}
