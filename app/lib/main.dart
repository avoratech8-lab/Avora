import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';

import 'src/api/api.dart';
import 'src/api/demo_api.dart';
import 'src/api/http_api.dart';
import 'src/app.dart';
import 'src/credentials.dart';
import 'src/preferences.dart';
import 'src/recipients.dart';
import 'src/security.dart';

/// Set at build time: flutter build apk --dart-define=AVORA_API_URL=https://...
/// When it is empty the app runs in demo mode against an in-memory backend.
const apiUrl = String.fromEnvironment('AVORA_API_URL');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final KeyValueStore store = apiUrl.isEmpty ? MemoryKeyValueStore() : SecureKeyValueStore();
  // Everything that reads storage runs at once, so the first frame comes
  // as soon as the slowest read is done rather than after all of them.
  final (credentials, recipients, preferences, deviceName) = await (
    Credentials.load(store),
    RecentRecipients.load(store),
    Preferences.load(store),
    apiUrl.isEmpty ? Future.value('') : _deviceName(),
  ).wait;
  final AvoraApi api = apiUrl.isEmpty
      ? DemoAvoraApi(credentials: credentials)
      : HttpAvoraApi(baseUrl: Uri.parse(apiUrl), credentials: credentials, deviceName: deviceName);
  runApp(
    AvoraApp(
      api: api,
      credentials: credentials,
      recipients: recipients,
      preferences: preferences,
      security: await Security.load(store, DeviceBiometrics(), signedIn: credentials.signedIn),
    ),
  );
}

/// "Samsung SM-A155F" or "iPhone 15", for Me → Phones signed in.
Future<String> _deviceName() async {
  try {
    final info = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final a = await info.androidInfo;
      final brand = a.brand.isEmpty ? '' : '${a.brand[0].toUpperCase()}${a.brand.substring(1)} ';
      return '$brand${a.model}';
    }
    if (Platform.isIOS) return (await info.iosInfo).modelName;
  } catch (_) {
    // A name is nice to have; the server falls back to "A phone".
  }
  return '';
}
