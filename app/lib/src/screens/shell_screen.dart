import 'package:flutter/material.dart';

import '../api/models.dart';
import '../app.dart';
import 'activity_tab.dart';
import 'home_tab.dart';
import 'profile_tab.dart';
import 'savings_screens.dart';

/// The signed-in app: Home, Savings, Activity and Me tabs sharing one copy
/// of the wallet and statement.
class ShellScreen extends StatefulWidget {
  const ShellScreen({super.key});

  @override
  State<ShellScreen> createState() => ShellScreenState();
}

class ShellScreenState extends State<ShellScreen> {
  int _tab = 0;
  final _savings = GlobalKey<SavingsTabState>();
  Wallet? wallet;
  List<StatementLine> lines = const [];
  int unread = 0;
  Profile? profile;
  int tier = 1;
  bool loading = true;
  Object? error;

  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    // Show what Home looked like last time straight away, then refresh.
    final cached = AppScope.of(context).preferences.cachedHome;
    if (cached != null) {
      wallet = cached.$1;
      lines = cached.$2;
      loading = false;
    }
    refresh();
  }

  Future<void> refresh() async {
    final scope = AppScope.of(context);
    final api = scope.api;
    // All four in parallel: one round trip instead of three. The bell and
    // the tier are extras, so Home still shows if they fail.
    final unreadF = api.notifications().then((n) => n.$2, onError: (_) => unread);
    final tierF = api.kycStatus().then((s) => s.tier, onError: (_) => tier);
    final profileF = api.profile().then<Profile?>((p) => p, onError: (_) => profile);
    try {
      final (w, l) = await (api.wallet(), api.statement()).wait;
      final unreadNow = await unreadF;
      final tierNow = await tierF;
      final profileNow = await profileF;
      if (!mounted) return;
      setState(() {
        wallet = w;
        lines = l;
        unread = unreadNow;
        tier = tierNow;
        profile = profileNow;
        error = null;
        loading = false;
      });
      scope.preferences.cacheHome(w, l);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        error = e;
        loading = false;
      });
    }
  }

  static const homeTab = 0, savingsTab = 1, activityTab = 2, meTab = 3;

  void showTab(int i) {
    setState(() => _tab = i);
    if (i == savingsTab) _savings.currentState?.refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          HomeTab(shell: this),
          SavingsTab(key: _savings, shell: this),
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
            icon: Icon(Icons.savings_outlined),
            selectedIcon: Icon(Icons.savings_rounded),
            label: 'Savings',
          ),
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
