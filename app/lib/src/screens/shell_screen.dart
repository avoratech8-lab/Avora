import 'package:flutter/material.dart';

import '../api/models.dart';
import '../app.dart';
import 'activity_tab.dart';
import 'home_tab.dart';
import 'profile_tab.dart';

/// The signed-in app: Home, Activity and Me tabs sharing one copy of the
/// wallet and statement.
class ShellScreen extends StatefulWidget {
  const ShellScreen({super.key});

  @override
  State<ShellScreen> createState() => ShellScreenState();
}

class ShellScreenState extends State<ShellScreen> {
  int _tab = 0;
  Wallet? wallet;
  List<StatementLine> lines = const [];
  bool loading = true;
  Object? error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (wallet == null && error == null) refresh();
  }

  Future<void> refresh() async {
    final api = AppScope.of(context).api;
    try {
      final results = await Future.wait([api.wallet(), api.statement()]);
      if (!mounted) return;
      setState(() {
        wallet = results[0] as Wallet;
        lines = results[1] as List<StatementLine>;
        error = null;
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        error = e;
        loading = false;
      });
    }
  }

  void showTab(int i) => setState(() => _tab = i);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          HomeTab(shell: this),
          ActivityTab(shell: this),
          ProfileTab(shell: this),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: showTab,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home_rounded), label: 'Home'),
          NavigationDestination(
            icon: Icon(Icons.receipt_long_outlined),
            selectedIcon: Icon(Icons.receipt_long_rounded),
            label: 'Activity',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline_rounded),
            selectedIcon: Icon(Icons.person_rounded),
            label: 'Me',
          ),
        ],
      ),
    );
  }
}
