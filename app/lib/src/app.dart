import 'package:flutter/material.dart';

import 'api/api.dart';
import 'credentials.dart';
import 'recipients.dart';
import 'screens/lock_screen.dart';
import 'screens/shell_screen.dart';
import 'screens/welcome_screen.dart';
import 'security.dart';
import 'ui/theme.dart';

/// Gives every screen the API, the sign-in state and saved recipients.
class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.api,
    required this.credentials,
    required this.recipients,
    required this.security,
    required super.child,
  });

  final AvoraApi api;
  final Credentials credentials;
  final RecentRecipients recipients;
  final Security security;

  static AppScope of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!;

  @override
  bool updateShouldNotify(AppScope old) =>
      api != old.api || credentials != old.credentials || recipients != old.recipients || security != old.security;
}

class AvoraApp extends StatefulWidget {
  const AvoraApp({super.key, required this.api, required this.credentials, required this.recipients, this.security});

  final AvoraApi api;
  final Credentials credentials;
  final RecentRecipients recipients;

  /// The app lock and biometrics; none if left out.
  final Security? security;

  @override
  State<AvoraApp> createState() => _AvoraAppState();
}

class _AvoraAppState extends State<AvoraApp> with WidgetsBindingObserver {
  final _navigator = GlobalKey<NavigatorState>();
  late final Security _security = widget.security ?? Security.inMemory();

  @override
  void initState() {
    super.initState();
    widget.credentials.addListener(_onCredentials);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    widget.credentials.removeListener(_onCredentials);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Signing in or out swaps the first screen, so close anything opened on top.
  void _onCredentials() {
    _navigator.currentState?.popUntil((r) => r.isFirst);
    if (!widget.credentials.signedIn) _security.signedOut();
  }

  // Only a real trip away counts: the fingerprint prompt makes the app
  // inactive but never paused.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) _security.left(DateTime.now());
    if (state == AppLifecycleState.resumed) _security.returned(DateTime.now(), signedIn: widget.credentials.signedIn);
  }

  @override
  Widget build(BuildContext context) {
    final api = widget.api;
    final credentials = widget.credentials;
    return AppScope(
      api: api,
      credentials: credentials,
      recipients: widget.recipients,
      security: _security,
      child: MaterialApp(
        navigatorKey: _navigator,
        title: 'Avora',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        builder: (context, child) {
          // The lock covers everything, sheets included, and keeps the
          // screens underneath alive so nothing is lost.
          final app = ListenableBuilder(
            listenable: _security,
            builder: (context, _) {
              final locked = _security.locked && credentials.signedIn;
              return Stack(
                children: [
                  Offstage(
                    offstage: locked,
                    child: TickerMode(enabled: !locked, child: child!),
                  ),
                  if (locked) const LockScreen(),
                ],
              );
            },
          );
          return api.isDemo
              ? Banner(
                  message: 'DEMO',
                  location: BannerLocation.topEnd,
                  color: Brand.warning,
                  textStyle: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Colors.white),
                  child: app,
                )
              : app;
        },
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
