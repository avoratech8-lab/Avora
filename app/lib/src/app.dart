import 'package:flutter/material.dart';

import 'api/api.dart';
import 'credentials.dart';
import 'screens/home_screen.dart';
import 'screens/phone_screen.dart';

/// Gives every screen the API and the sign-in state.
class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.api, required this.credentials, required super.child});

  final AvoraApi api;
  final Credentials credentials;

  static AppScope of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!;

  @override
  bool updateShouldNotify(AppScope old) => api != old.api || credentials != old.credentials;
}

const brandGreen = Color(0xFF0B6E4F);

class AvoraApp extends StatefulWidget {
  const AvoraApp({super.key, required this.api, required this.credentials});

  final AvoraApi api;
  final Credentials credentials;

  @override
  State<AvoraApp> createState() => _AvoraAppState();
}

class _AvoraAppState extends State<AvoraApp> {
  final _navigator = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    widget.credentials.addListener(_onCredentials);
  }

  @override
  void dispose() {
    widget.credentials.removeListener(_onCredentials);
    super.dispose();
  }

  // Signing in or out swaps the first screen, so close anything opened on top.
  void _onCredentials() => _navigator.currentState?.popUntil((r) => r.isFirst);

  @override
  Widget build(BuildContext context) {
    final api = widget.api;
    final credentials = widget.credentials;
    return AppScope(
      api: api,
      credentials: credentials,
      child: MaterialApp(
        navigatorKey: _navigator,
        title: 'Avora',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: brandGreen, useMaterial3: true),
        darkTheme: ThemeData(colorSchemeSeed: brandGreen, brightness: Brightness.dark, useMaterial3: true),
        builder: (context, child) => api.isDemo
            ? Banner(message: 'DEMO', location: BannerLocation.topEnd, color: Colors.orange.shade800, child: child!)
            : child!,
        // Rebuilds when the token appears or disappears, including when the
        // server says the session is over.
        home: ListenableBuilder(
          listenable: credentials,
          builder: (context, _) => credentials.signedIn ? const HomeScreen() : const PhoneScreen(),
        ),
      ),
    );
  }
}

/// Shows an API error (or anything else) as a snackbar.
void showError(BuildContext context, Object error) {
  final msg = error is ApiException ? error.message : 'Something went wrong. Please try again.';
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));
}
