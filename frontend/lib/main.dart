import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'app/app.dart';
import 'app/theme.dart';
import 'core/network/api_client.dart';
import 'core/storage/session_store.dart';
import 'core/widgets/app_widgets.dart';
import 'features/auth/data/auth_repository.dart';
import 'features/auth/presentation/auth_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    const baseUrl = String.fromEnvironment('API_BASE_URL');
    final api = ApiClient(baseUrl, http.Client(), allowLocalHttp: kDebugMode);
    final store = !kIsWeb && defaultTargetPlatform == TargetPlatform.android
        ? AndroidSessionStore()
        : MemorySessionStore();
    runApp(ExpenseTrackerApp(auth: AuthController(AuthRepository(api), store)));
  } on ApiFailure catch (error) {
    runApp(
      MaterialApp(
        title: 'AI Expense Tracker',
        theme: darkTheme(),
        debugShowCheckedModeBanner: false,
        home: AuthScreenLayout(
          midnight: true,
          child: AppErrorMessage(error.message),
        ),
      ),
    );
  }
}
