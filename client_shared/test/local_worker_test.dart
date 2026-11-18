import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jain_client/jain_client.dart';

void main() {
  final key = Platform.environment['JAIN_TEST_FIXTURE_KEY'];
  final base =
      Platform.environment['JAIN_TEST_API_URL'] ?? 'http://127.0.0.1:8787';

  test(
    'customer and admin Dart clients approve a profile through the local Worker',
    () async {
      final emailSuffix = DateTime.now().microsecondsSinceEpoch;
      final customerEmail = 'customer-$emailSuffix@example.test';
      final adminEmail = 'admin-$emailSuffix@example.test';
      const storage = FlutterSecureStorage();
      FlutterSecureStorage.setMockInitialValues({});
      final customer = Api(base: base, storage: storage)..fixtureKey = key!;
      final admin = Api(base: base, storage: storage)..fixtureKey = key;
      addTearDown(customer.dispose);
      addTearDown(admin.dispose);
      expect(customer.localDebug, isTrue);

      final bootstrap = HttpClient();
      addTearDown(() => bootstrap.close(force: true));
      final request = await bootstrap.postUrl(
        Uri.parse(base).resolve('/_local/admin'),
      );
      request.headers.contentType = ContentType.json;
      request.headers.set('X-Local-Fixture-Key', key);
      request.write(jsonEncode({'email': adminEmail}));
      final response = await request.close();
      expect(response.statusCode, 201);
      await response.drain<void>();

      Future<void> signIn(Api api, String email, String role) async {
        final otp = await api.requestCode(email);
        await api.signIn(
          otp['challengeId'] as String,
          otp['localTestCode'] as String,
          role,
        );
        expect(api.account?.role, role);
      }

      await signIn(customer, customerEmail, 'customer');
      await signIn(admin, adminEmail, 'admin');
      final draft = await customer.post('/profiles', {
        'consent': true,
        'data': {
          'name': 'Synthetic integration candidate',
          'dob': '1994-04-09',
          'gender': 'woman',
          'city': 'Pune',
          'country': 'India',
          'tradition': 'Digambara',
        },
      });
      final id = draft['id'] as String;
      final revision = await customer.post('/profiles/$id/submit', {
        'version': draft['version'],
      });
      await admin.post('/admin/revisions/${revision['id']}/decision', {
        'decision': 'approved',
        'reason': 'Synthetic integration check',
      });
      final accepted = Draft.fromJson(await customer.get('/profiles/$id'));
      expect(accepted.record['publishedId'], revision['id']);
      await customer.logout();
      await admin.logout();
    },
    skip: key == null
        ? 'Start an isolated fixture Worker and set JAIN_TEST_FIXTURE_KEY.'
        : false,
  );
}
