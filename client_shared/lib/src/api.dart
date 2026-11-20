import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ChangeNotifier, kDebugMode;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

typedef Json = Map<String, dynamic>;
const productionApiBase =
    'https://jain-matrimonial-api.avtejasupadhye-9a.workers.dev';
const apiBase = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: productionApiBase,
);

Json asJson(Object? value) => Map<String, dynamic>.from(value as Map);
List<Json> items(Json value) => (value['items'] as List).map(asJson).toList();
String label(Object? value) => (value?.toString() ?? '').replaceAll('_', ' ');

class ApiError implements Exception {
  const ApiError(this.status, this.message, this.fields);
  final int status;
  final String message;
  final Json fields;

  @override
  String toString() => fields.isEmpty
      ? message
      : '$message ${fields.entries.map((e) => '${e.key}: ${e.value}').join(' ')}';
}

class Account {
  const Account(this.id, this.role, this.email);
  factory Account.fromJson(Json json) => Account(
    json['id'] as String,
    json['role'] as String,
    json['email'] as String? ?? '',
  );
  final String id;
  final String role;
  final String email;
}

class Candidate {
  const Candidate(this.id, this.values);
  factory Candidate.fromJson(Json json) =>
      Candidate(json['id'] as String, json);
  final String id;
  final Json values;

  String get title => '${values['age']} years · ${values['city']}';
  String get summary => [
    values['occupation'],
    values['qualification'],
    values['tradition'],
  ].whereType<String>().join(' · ');
}

class Draft {
  const Draft(this.id, this.version, this.data, this.record);
  factory Draft.fromJson(Json json) => Draft(
    json['id'] as String,
    json['version'] as int,
    asJson(json['data']),
    json,
  );
  final String id;
  final int version;
  final Json data;
  final Json record;
}

class Api extends ChangeNotifier {
  Api({
    String base = apiBase,
    FlutterSecureStorage? storage,
    String? sessionScope,
    this.persistSession = true,
  }) : origin = Uri.parse(base),
       _refreshKey = sessionScope == null
           ? 'jain-matrimonial-refresh'
           : 'jain-matrimonial-refresh-$sessionScope',
       _storage = storage ?? const FlutterSecureStorage() {
    if (origin.scheme != 'https' && !localDebug) {
      throw ArgumentError('HTTPS is required for the Worker API');
    }
  }

  final Uri origin;
  final FlutterSecureStorage _storage;
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 12);
  final Random _random = Random.secure();
  final String _refreshKey;
  final bool persistSession;
  String? _access;
  String? _refresh;
  Future<void>? _rotation;
  Account? account;
  String fixtureKey = '';

  bool get localDebug =>
      kDebugMode && ['localhost', '127.0.0.1'].contains(origin.host);

  Future<void> restore() async {
    if (!persistSession) return;
    _refresh = await _storage.read(key: _refreshKey);
    if (_refresh == null) return;
    try {
      await _rotate();
      account = Account.fromJson(await get('/me'));
      notifyListeners();
    } on ApiError catch (error) {
      if (error.status == 401) await clear();
      if (error.status != 401) rethrow;
    }
  }

  Future<Json> requestCode(String email) =>
      post('/auth/otp/request', {'email': email}, authenticated: false);

  Future<void> signInAdmin(String password) async {
    final data = await post('/admin/auth/login', {
      'password': password,
    }, authenticated: false);
    final found = Account.fromJson(asJson(data['account']));
    if (found.role != 'admin') {
      throw const ApiError(
        403,
        'This account cannot use this application.',
        {},
      );
    }
    await _acceptTokens(data);
    account = found;
    notifyListeners();
  }

  Future<void> changeAdminPassword(
    String current,
    String next,
    String confirmation,
  ) async {
    await post('/admin/auth/password', {
      'currentPassword': current,
      'newPassword': next,
      'confirmPassword': confirmation,
    });
    await clear();
  }

  Future<void> signIn(
    String challengeId,
    String code,
    String expectedRole,
  ) async {
    final data = await post('/auth/otp/verify', {
      'challengeId': challengeId,
      'code': code,
    }, authenticated: false);
    final found = Account.fromJson(asJson(data['account']));
    if (found.role != expectedRole) {
      await _send(
        'POST',
        '/auth/logout',
        {},
        token: data['accessToken'] as String,
      );
      throw const ApiError(
        403,
        'This account cannot use this application.',
        {},
      );
    }
    await _acceptTokens(data);
    account = found;
    notifyListeners();
  }

  Future<void> _acceptTokens(Json data) async {
    final refresh = data['refreshToken'] as String;
    if (persistSession) await _storage.write(key: _refreshKey, value: refresh);
    _refresh = refresh;
    _access = data['accessToken'] as String;
  }

  Future<void> _rotate() async {
    final running = _rotation;
    if (running != null) return running;
    final refresh = _refresh;
    if (refresh == null) throw const ApiError(401, 'Sign in to continue.', {});
    final future = () async {
      final tokens = await _send('POST', '/auth/refresh', {
        'refreshToken': refresh,
      });
      if (_refresh != refresh) {
        throw const ApiError(401, 'Sign in to continue.', {});
      }
      await _acceptTokens(tokens);
    }();
    _rotation = future;
    try {
      await future;
    } finally {
      _rotation = null;
    }
  }

  Future<void> clear() async {
    _access = null;
    _refresh = null;
    account = null;
    notifyListeners();
    if (persistSession) await _storage.delete(key: _refreshKey);
  }

  Future<void> logout() async {
    try {
      await post('/auth/logout', {});
    } finally {
      await clear();
    }
  }

  Future<Json> get(String path) => call('GET', path);
  Future<Json> post(String path, Json data, {bool authenticated = true}) =>
      call('POST', path, data, authenticated);
  Future<Json> put(String path, Json data) => call('PUT', path, data);
  Future<Json> delete(String path) => call('DELETE', path);
  String query(String route, Json data) => Uri(
    path: route,
    queryParameters: {
      for (final e in data.entries)
        if (e.value != null && e.value.toString().isNotEmpty)
          e.key: e.value.toString(),
    },
  ).toString();

  Future<Json> call(
    String method,
    String path, [
    Json? data,
    bool authenticated = true,
  ]) async {
    final key = method == 'GET'
        ? null
        : List.generate(
            24,
            (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
          ).join();
    return _withSession(
      (token) => _send(method, path, data, token: token, key: key),
      authenticated,
    );
  }

  Future<T> _withSession<T>(
    Future<T> Function(String? token) send,
    bool authenticated,
  ) async {
    final token = authenticated ? _access : null;
    try {
      return await send(token);
    } on ApiError catch (error) {
      if (error.status != 401 || !authenticated || _refresh == null) rethrow;
      try {
        if (_access == token) await _rotate();
      } on ApiError catch (refreshError) {
        if (refreshError.status == 401) await clear();
        rethrow;
      }
      try {
        return await send(_access);
      } on ApiError catch (retryError) {
        if (retryError.status == 401) await clear();
        rethrow;
      }
    }
  }

  Future<Json> uploadDocument(
    String path,
    Uint8List bytes,
    String mime,
    String sha256,
  ) => _withSession(
    (token) => _send(
      'PUT',
      path,
      null,
      token: token,
      binary: bytes,
      mime: mime,
      sha256: sha256,
    ),
    true,
  );

  Future<Uint8List> downloadDocument(String path) => _withSession(
    (token) => _exchange('GET', path, token, 'application/octet-stream', (
      _,
      response,
    ) async {
      if (response.statusCode != 200) {
        await _responseJson(response);
        throw const ApiError(0, 'The document could not be downloaded.', {});
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 20))) {
        if (bytes.length + chunk.length > 8 * 1024 * 1024) {
          throw const ApiError(0, 'The downloaded document exceeds 8 MiB.', {});
        }
        bytes.add(chunk);
      }
      return bytes.takeBytes();
    }),
    true,
  );

  Future<Json> _send(
    String method,
    String path,
    Json? data, {
    String? token,
    String? key,
    Uint8List? binary,
    String? mime,
    String? sha256,
  }) => _exchange(
    method,
    path,
    token,
    'application/json',
    (request, response) {
      return _responseJson(response);
    },
    prepare: (request) {
      if (key != null) request.headers.set('Idempotency-Key', key);
      if (binary != null) {
        request.headers.set(HttpHeaders.contentTypeHeader, mime!);
        request.headers.set('X-Content-SHA256', sha256!);
        request.contentLength = binary.length;
        request.add(binary);
      } else if (data != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(data));
      }
    },
  );

  Future<Json> _responseJson(HttpClientResponse response) async {
    final raw = await response
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 20));
    Json json;
    try {
      json = asJson(jsonDecode(raw));
    } catch (_) {
      throw const ApiError(
        0,
        'The Worker did not return a valid API response.',
        {},
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiError(
        response.statusCode,
        json['message']?.toString() ?? 'Request failed.',
        json['fields'] is Map ? asJson(json['fields']) : {},
      );
    }
    if (json['code'] != 'ok' || json['data'] is! Map) {
      throw const ApiError(
        0,
        'The Worker did not return a valid API response.',
        {},
      );
    }
    return asJson(json['data']);
  }

  Future<T> _exchange<T>(
    String method,
    String path,
    String? token,
    String accept,
    Future<T> Function(HttpClientRequest, HttpClientResponse) read, {
    void Function(HttpClientRequest)? prepare,
  }) async {
    final uri = origin.resolve(path);
    if (uri.origin != origin.origin)
      throw ArgumentError('API paths must stay on the configured origin');
    try {
      final request = await _http.openUrl(method, uri);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, accept);
      if (token != null)
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      if (localDebug && fixtureKey.isNotEmpty)
        request.headers.set('x-local-fixture-key', fixtureKey);
      prepare?.call(request);
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      return await read(request, response);
    } on ApiError {
      rethrow;
    } catch (_) {
      throw const ApiError(
        0,
        'The service could not be reached. Try again.',
        {},
      );
    }
  }

  @override
  void dispose() {
    _http.close(force: true);
    super.dispose();
  }
}
