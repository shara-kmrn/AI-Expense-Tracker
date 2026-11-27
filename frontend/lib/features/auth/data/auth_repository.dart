import '../../../core/network/api_client.dart';

class UserProfile {
  const UserProfile({
    required this.id,
    required this.fullName,
    required this.email,
    required this.createdAt,
    required this.updatedAt,
  });
  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
    id: _string(json, 'id'),
    fullName: _string(json, 'full_name'),
    email: _string(json, 'email'),
    createdAt: _date(json, 'created_at'),
    updatedAt: _date(json, 'updated_at'),
  );
  final String id;
  final String fullName;
  final String email;
  final DateTime createdAt;
  final DateTime updatedAt;
}

class Credentials {
  const Credentials(
    this.access,
    this.refresh,
    this.accessExpiresAt,
    this.refreshExpiresAt,
  );
  factory Credentials.fromJson(
    Map<String, dynamic> json,
    DateTime requestedAt,
  ) {
    final seconds = json['expires_in'];
    if (seconds is! int || seconds <= 0 || json['token_type'] != 'bearer') {
      throw _invalid;
    }
    return Credentials(
      _string(json, 'access_token'),
      _string(json, 'refresh_token'),
      requestedAt.add(Duration(seconds: seconds)),
      _date(json, 'refresh_expires_at'),
    );
  }
  final String access;
  final String refresh;
  final DateTime accessExpiresAt;
  final DateTime refreshExpiresAt;
}

const _invalid = ApiFailure(
  'The service returned an unexpected response.',
  uncertain: true,
);

String _string(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is String && value.isNotEmpty) return value;
  throw _invalid;
}

DateTime _date(Map<String, dynamic> json, String key) =>
    DateTime.tryParse(_string(json, key))?.toUtc() ?? (throw _invalid);

class AuthRepository {
  const AuthRepository(this._api);
  final ApiClient _api;

  Future<Credentials> login(String email, String password) async {
    final requestedAt = DateTime.now();
    return Credentials.fromJson(
      await _api.send(
        Endpoint.login,
        body: {'email': email, 'password': password},
      ),
      requestedAt,
    );
  }

  Future<Credentials> refresh(String refresh) async {
    final requestedAt = DateTime.now();
    return Credentials.fromJson(
      await _api.send(Endpoint.refresh, body: {'refresh_token': refresh}),
      requestedAt,
    );
  }

  Future<void> register(String name, String email, String password) async {
    await _api.send(
      Endpoint.register,
      body: {'full_name': name, 'email': email, 'password': password},
    );
  }

  Future<void> forgot(String email) async {
    await _api.send(Endpoint.forgot, body: {'email': email});
  }

  Future<void> reset(String code, String password) async {
    await _api.send(
      Endpoint.reset,
      body: {'reset_token': code, 'new_password': password},
    );
  }

  Future<UserProfile> profile(String access) async =>
      UserProfile.fromJson(await _api.send(Endpoint.profile, bearer: access));

  Future<UserProfile> edit(String access, String name) async =>
      UserProfile.fromJson(
        await _api.send(
          Endpoint.editProfile,
          bearer: access,
          body: {'full_name': name},
        ),
      );

  Future<void> changePassword(
    String access,
    String current,
    String next,
  ) async {
    await _api.send(
      Endpoint.changePassword,
      bearer: access,
      body: {'current_password': current, 'new_password': next},
    );
  }

  Future<void> delete(String access, String password) async {
    await _api.send(
      Endpoint.deleteAccount,
      bearer: access,
      body: {'current_password': password},
    );
  }

  Future<void> logout(String access) async {
    await _api.send(Endpoint.logout, bearer: access);
  }
}
