import 'package:flutter/material.dart';

import 'src/api/api.dart';
import 'src/api/demo_api.dart';
import 'src/api/http_api.dart';
import 'src/app.dart';
import 'src/credentials.dart';

/// Set at build time: flutter build apk --dart-define=AVORA_API_URL=https://...
/// When it is empty the app runs in demo mode against an in-memory backend.
const apiUrl = String.fromEnvironment('AVORA_API_URL');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final AvoraApi api;
  final Credentials credentials;
  if (apiUrl.isEmpty) {
    credentials = await Credentials.load(MemoryKeyValueStore());
    api = DemoAvoraApi(credentials: credentials);
  } else {
    credentials = await Credentials.load(SecureKeyValueStore());
    api = HttpAvoraApi(baseUrl: Uri.parse(apiUrl), credentials: credentials);
  }
  runApp(AvoraApp(api: api, credentials: credentials));
}
