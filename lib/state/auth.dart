import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';
import '../core/json.dart';
import '../core/storage.dart';
import '../data/repo.dart';

class AuthState {
  const AuthState({this.user, this.token, this.role, this.ready = false});
  final Json? user;
  final String? token;
  final String? role; // 'guest' | 'host'
  final bool ready; // session restored from the keystore

  bool get loggedIn => token != null && user != null;
  bool get isHost => role == 'host';
  String get name => asString(user?['name']);
  String get firstName => name.trim().split(' ').first;
  String get email => asString(user?['email']);
  String get id => asString(user?['_id'] ?? user?['id']);
  List<String> get capabilities => asStringList(user?['capabilities']);

  AuthState copyWith({Json? user}) => AuthState(user: user ?? this.user, token: token, role: role, ready: ready);
}

class AuthController extends Notifier<AuthState> {
  @override
  AuthState build() {
    api.onSessionExpired = () => logout();
    return const AuthState();
  }

  Future<void> restore() async {
    // Three keystore reads in parallel instead of one after another.
    final (token, role, user) = await (SecureStore.token(), SecureStore.role(), SecureStore.user()).wait;
    if (token != null && role != null && user != null) {
      api.token = token;
      state = AuthState(user: user, token: token, role: role, ready: true);
    } else {
      state = const AuthState(ready: true);
    }
  }

  /// Returns `mustChangePassword` – an account created at checkout signs in
  /// with an emailed password and should change it straight away.
  Future<bool> login(String email, String password, String lang) async {
    final r = await authRepo.login(email, password, lang);
    final token = asString(r['token']);
    final role = asString(r['role'], 'guest');
    final user = asMap(r['data']);
    await _apply(token, role, user);
    return asBool(r['mustChangePassword']);
  }

  Future<void> register(Json body) => authRepo.register(body);

  /// Traveller and host are separate accounts linked by a verified email; the
  /// server issues a token for the other side (AuthContext.requestModeSwitch).
  Future<void> switchMode(String mode, String lang) async {
    final r = await authRepo.switchMode(mode, lang);
    final token = asString(r['token']);
    if (token.isEmpty) throw ApiException('Mode switch failed');
    await _apply(token, asString(r['role'], mode), asMap(r['data'] ?? r['user']));
  }

  Future<void> updateUser(Json patch) async {
    final next = {...?state.user, ...patch};
    state = state.copyWith(user: next);
    await SecureStore.saveUser(next);
  }

  Future<void> logout() async {
    api.token = null;
    api.clearCache();
    await SecureStore.clearSession();
    state = const AuthState(ready: true);
  }

  Future<void> _apply(String token, String role, Json user) async {
    api.token = token;
    api.clearCache();
    await SecureStore.saveSession(token: token, role: role, user: user);
    state = AuthState(user: user, token: token, role: role, ready: true);
  }
}

final authProvider = NotifierProvider<AuthController, AuthState>(AuthController.new);
