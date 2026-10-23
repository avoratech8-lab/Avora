import 'package:flutter/material.dart';

import 'src/api/api.dart';
import 'src/api/demo_api.dart';
import 'src/api/http_api.dart';
import 'src/app.dart';
import 'src/credentials.dart';
import 'src/recipients.dart';

/// Set at build time: flutter build apk --dart-define=AVORA_API_URL=https://...
/// When it is empty the app runs in demo mode against an in-memory backend.
const apiUrl = String.fromEnvironment('AVORA_API_URL');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final KeyValueStore store = apiUrl.isEmpty ? MemoryKeyValueStore() : SecureKeyValueStore();
  final credentials = await Credentials.load(store);
  final AvoraApi api = apiUrl.isEmpty
      ? DemoAvoraApi(credentials: credentials)
      : HttpAvoraApi(baseUrl: Uri.parse(apiUrl), credentials: credentials);
  runApp(AvoraApp(api: api, credentials: credentials, recipients: await RecentRecipients.load(store)));
}
