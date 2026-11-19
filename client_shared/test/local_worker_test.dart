import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jain_client/jain_client.dart';

void main() {
  final key = Platform.environment['JAIN_TEST_FIXTURE_KEY'];
  final adminPassword = Platform.environment['JAIN_TEST_ADMIN_PASSWORD'];
  final base =
      Platform.environment['JAIN_TEST_API_URL'] ?? 'http://127.0.0.1:8787';

  test(
    'customer and admin Dart clients approve a profile through the local Worker',
    () async {
      final emailSuffix = DateTime.now().microsecondsSinceEpoch;
      final customerEmail = 'customer-$emailSuffix@example.test';
      const storage = FlutterSecureStorage();
      FlutterSecureStorage.setMockInitialValues({});
      final customer = Api(base: base, storage: storage)..fixtureKey = key!;
      final admin = Api(base: base, persistSession: false);
      addTearDown(customer.dispose);
      addTearDown(admin.dispose);
      expect(customer.localDebug, isTrue);

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
      await admin.signInAdmin(adminPassword!);
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
    skip: key == null || adminPassword == null
        ? 'Provision an isolated local Admin and set the local test password and fixture key.'
        : false,
  );
}
