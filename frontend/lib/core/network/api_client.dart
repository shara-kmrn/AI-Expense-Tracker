import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

enum Endpoint {
  login('POST', 'auth/login', 200),
  register('POST', 'auth/register', 201),
  forgot('POST', 'auth/forgot-password', 202),
  reset('POST', 'auth/reset-password', 204),
  refresh('POST', 'auth/refresh', 200),
  logout('POST', 'auth/logout', 204),
  profile('GET', 'users/me', 200),
  editProfile('PATCH', 'users/me', 200),
  changePassword('POST', 'auth/change-password', 204),
  deleteAccount('DELETE', 'users/me', 204);

  const Endpoint(this.method, this.path, this.status);
  final String method;
  final String path;
  final int status;
}

class ApiFailure implements Exception {
  const ApiFailure(this.message, {this.status, this.uncertain = false});
  final String message;
  final int? status;
  final bool uncertain;
}

class ApiClient {
  ApiClient(
    String baseUrl,
    this._http, {
    required bool allowLocalHttp,
    this.timeout = const Duration(seconds: 12),
  }) : _base = _validate(baseUrl, allowLocalHttp);

  final http.Client _http;
  final Uri _base;
  final Duration timeout;

  static Uri _validate(String input, bool local) {
    final uri = Uri.tryParse(input);
    if (uri == null ||
        uri.host.isEmpty ||
        uri.authority.contains('@') ||
        uri.hasQuery ||
        uri.hasFragment ||
        !const {'/api/v1', '/api/v1/'}.contains(uri.path) ||
        !(uri.scheme == 'https' ||
            (local &&
                uri.scheme == 'http' &&
                const {'localhost', '127.0.0.1'}.contains(uri.host)))) {
      throw const ApiFailure(
        'Configure a trusted HTTPS API URL ending in /api/v1.',
      );
    }
    return uri.replace(path: '/api/v1/');
  }

  Future<Map<String, dynamic>> send(
    Endpoint endpoint, {
    Map<String, String>? body,
    String? bearer,
  }) async {
    final abort = Completer<void>();
    final request = http.AbortableRequest(
      endpoint.method,
      _base.resolve(endpoint.path),
      abortTrigger: abort.future,
    )..followRedirects = false;
    request.headers['Accept'] = 'application/json';
    if (bearer != null) request.headers['Authorization'] = 'Bearer $bearer';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    late http.Response response;
    try {
      response = await _http
          .send(request)
          .then(http.Response.fromStream)
          .timeout(
            timeout,
            onTimeout: () {
              abort.complete();
              throw TimeoutException('API timeout');
            },
          );
    } on TimeoutException {
      throw const ApiFailure(
        'The request timed out. Check your connection.',
        uncertain: true,
      );
    } on http.ClientException {
      throw const ApiFailure(
        'Could not connect to the service.',
        uncertain: true,
      );
    }
    if (response.statusCode != endpoint.status) {
      throw _failure(endpoint, response);
    }
    if (response.statusCode == 204 || endpoint == Endpoint.forgot) {
      return const {};
    }
    try {
      final json = jsonDecode(utf8.decode(response.bodyBytes));
      if (json is Map<String, dynamic>) return json;
    } on FormatException {
      // The response body can contain secrets and must not be surfaced.
    }
    throw const ApiFailure(
      'The service returned an unexpected response.',
      uncertain: true,
    );
  }

  ApiFailure _failure(Endpoint endpoint, http.Response response) {
    final code = response.statusCode;
    final message = switch (code) {
      400 when endpoint == Endpoint.reset =>
        'That recovery code is invalid or expired.',
      400 when endpoint == Endpoint.changePassword =>
        'Check your current password and choose a different new password.',
      400 when endpoint == Endpoint.deleteAccount =>
        'Your current password was incorrect.',
      401 when endpoint == Endpoint.login => 'Email or password is incorrect.',
      401 => 'Your session ended. Sign in again.',
      409 when endpoint == Endpoint.register =>
        'An account could not be created with that email.',
      422 => 'Check the information you entered.',
      429 => 'Too many requests. Wait a moment and try again.',
      _ => 'The service could not complete your request.',
    };
    return ApiFailure(message, status: code, uncertain: code >= 500);
  }
}
