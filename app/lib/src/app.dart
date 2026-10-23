import 'package:flutter/material.dart';

import 'api/api.dart';
import 'credentials.dart';
import 'recipients.dart';
import 'screens/shell_screen.dart';
import 'screens/welcome_screen.dart';
import 'ui/theme.dart';

/// Gives every screen the API, the sign-in state and saved recipients.
class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.api,
    required this.credentials,
    required this.recipients,
    required super.child,
  });

  final AvoraApi api;
  final Credentials credentials;
  final RecentRecipients recipients;

  static AppScope of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!;

  @override
  bool updateShouldNotify(AppScope old) =>
      api != old.api || credentials != old.credentials || recipients != old.recipients;
}

class AvoraApp extends StatefulWidget {
  const AvoraApp({super.key, required this.api, required this.credentials, required this.recipients});

  final AvoraApi api;
  final Credentials credentials;
  final RecentRecipients recipients;

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
      recipients: widget.recipients,
      child: MaterialApp(
        navigatorKey: _navigator,
        title: 'Avora',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        builder: (context, child) => api.isDemo
            ? Banner(
                message: 'DEMO',
                location: BannerLocation.topEnd,
                color: Brand.warning,
                textStyle: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Colors.white),
                child: child!,
              )
            : child!,
        // Rebuilds when the token appears or disappears, including when the
        // server says the session is over.
        home: ListenableBuilder(
          listenable: credentials,
          builder: (context, _) => credentials.signedIn ? const ShellScreen() : const WelcomeScreen(),
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

void showMessage(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));
}
