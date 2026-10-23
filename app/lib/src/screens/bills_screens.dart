import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/api.dart';
import '../api/models.dart';
import '../app.dart';
import '../money.dart';
import '../ui/widgets.dart';
import 'bill_receipt_screen.dart';
import 'send_screen.dart';

String categoryTitle(BillCategory c) => switch (c) {
  BillCategory.airtime => 'Buy airtime',
  BillCategory.data => 'Buy data',
  BillCategory.electricity => 'Pay electricity',
  BillCategory.tv => 'Pay for TV',
};

/// Airtime, data, electricity and TV: pick the provider, enter the phone,
/// meter or smartcard, choose a plan or amount, confirm with the PIN.
class BillerScreen extends StatefulWidget {
  const BillerScreen({super.key, required this.category});

  final BillCategory category;

  @override
  State<BillerScreen> createState() => _BillerScreenState();
}

class _BillerScreenState extends State<BillerScreen> {
  final _customer = TextEditingController();
  final _amount = TextEditingController();
  List<Biller>? _billers;
  Object? _loadError;
  Biller? _biller;
  BillPlan? _plan;
  String? _customerName;
  String? _customerError;
  bool _looking = false;
  int _lookup = 0;

  BillCategory get _cat => widget.category;
  bool get _isPhone => _cat == BillCategory.airtime || _cat == BillCategory.data;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_billers == null && _loadError == null) _load();
  }

  Future<void> _load() async {
    try {
      final all = await AppScope.of(context).api.billers();
      if (!mounted) return;
      final mine = all.where((b) => b.category == _cat).toList();
      setState(() {
        _billers = mine;
        _biller = mine.isEmpty ? null : mine.first;
      });
    } catch (e) {
      if (mounted) setState(() => _loadError = e);
    }
  }

  @override
  void dispose() {
    _customer.dispose();
    _amount.dispose();
    super.dispose();
  }

  void _pickBiller(Biller b) {
    setState(() {
      _biller = b;
      _plan = null;
    });
    _customerChanged();
  }

  void _customerChanged() {
    final id = ++_lookup;
    setState(() {
      _customerName = null;
      _customerError = null;
      _looking = false;
    });
    final b = _biller;
    final c = _customer.text.trim();
    if (b == null || !b.needsLookup || c.length < 10) return;
    setState(() => _looking = true);
    AppScope.of(context).api
        .validateBillCustomer(billerId: b.id, customer: c)
        .then(
          (name) {
            if (mounted && id == _lookup) setState(() => _customerName = name);
          },
          onError: (Object e) {
            if (mounted && id == _lookup) {
              setState(() => _customerError = e is ApiException ? e.message : "We couldn't check that number.");
            }
          },
        )
        .whenComplete(() {
          if (mounted && id == _lookup) setState(() => _looking = false);
        });
  }

  int? get _chosenAmount => _biller?.hasPlans ?? false ? _plan?.amount : parseNaira(_amount.text);

  String? get _amountProblem {
    final b = _biller;
    final a = _chosenAmount;
    if (b == null || b.hasPlans || a == null) return null;
    if (a < b.minAmount) return 'Minimum is ${formatNaira(b.minAmount)}';
    if (a > b.maxAmount) return 'Maximum is ${formatNaira(b.maxAmount)}';
    return null;
  }

  bool get _ready {
    final b = _biller;
    if (b == null || _chosenAmount == null || _amountProblem != null) return false;
    final c = _customer.text.trim();
    if (_isPhone) return RegExp(r'^0[789][01]\d{8}$').hasMatch(c);
    return _customerName != null;
  }

  Future<void> _continue() async {
    final b = _biller!;
    final amount = _chosenAmount!;
    final customer = _customer.text.trim();
    final api = AppScope.of(context).api;
    final payment = await showModalBottomSheet<BillPayment>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ConfirmSheet<BillPayment>(
        title: categoryTitle(_cat),
        avatar: b.name,
        headline: formatNaira(amount),
        rows: [
          ('Provider', b.name),
          if (_plan != null) ('Plan', _plan!.name),
          (b.customerLabel, customer),
          if (_customerName != null && _customerName!.isNotEmpty) ('Name', _customerName!),
          ('Fee', 'Free'),
          ('Total', formatNaira(amount)),
        ],
        footnote: 'If it fails, the money comes straight back to your wallet.',
        action: (pin, key) => api.payBill(
          billerId: b.id,
          planCode: _plan?.code,
          customer: customer,
          amount: amount,
          pin: pin,
          idempotencyKey: key,
        ),
      ),
    );
    if (payment == null || !mounted) return;
    final p = payment;
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => BillReceiptScreen(paymentId: p.id, initial: p),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final billers = _billers;
    final b = _biller;
    return Scaffold(
      appBar: AppBar(title: Text(categoryTitle(_cat))),
      body: SafeArea(
        child: billers == null
            ? Center(
                child: _loadError == null
                    ? const CircularProgressIndicator()
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text("We couldn't load providers."),
                          TextButton(
                            onPressed: () {
                              setState(() => _loadError = null);
                              _load();
                            },
                            child: const Text('Try again'),
                          ),
                        ],
                      ),
              )
            : Column(
                children: [
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                      children: [
                        Text('Provider', style: theme.textTheme.labelMedium),
                        const SizedBox(height: 10),
                        _ProviderGrid(billers: billers, selected: b, onPick: _pickBiller),
                        const SizedBox(height: 20),
                        Text(b?.customerLabel ?? 'Number', style: theme.textTheme.labelMedium),
                        const SizedBox(height: 8),
                        TextField(
                          key: const Key('bill-customer'),
                          controller: _customer,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(13),
                          ],
                          style: theme.textTheme.titleMedium?.copyWith(letterSpacing: 1.2),
                          decoration: InputDecoration(
                            hintText: _isPhone
                                ? '0803 123 4567'
                                : 'Enter ${b?.customerLabel.toLowerCase() ?? 'number'}',
                            errorText: _customerError,
                            prefixIcon: Icon(_isPhone ? Icons.phone_android_rounded : Icons.numbers_rounded),
                            suffixIcon: _looking
                                ? const Padding(
                                    padding: EdgeInsets.all(16),
                                    child: SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    ),
                                  )
                                : null,
                          ),
                          onChanged: (_) => _customerChanged(),
                        ),
                        if (_customerName != null && _customerName!.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Row(
                              children: [
                                Icon(Icons.verified_rounded, size: 18, color: theme.colorScheme.primary),
                                const SizedBox(width: 6),
                                Text(
                                  _customerName!,
                                  style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary),
                                ),
                              ],
                            ),
                          ),
                        const SizedBox(height: 20),
                        if (b != null && b.hasPlans) ...[
                          Text(_cat == BillCategory.data ? 'Bundle' : 'Package', style: theme.textTheme.labelMedium),
                          const SizedBox(height: 10),
                          _PlanGrid(plans: b.plans, selected: _plan, onPick: (p) => setState(() => _plan = p)),
                        ] else ...[
                          Text('Amount', style: theme.textTheme.labelMedium),
                          const SizedBox(height: 8),
                          TextField(
                            key: const Key('bill-amount'),
                            controller: _amount,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            style: theme.textTheme.titleMedium,
                            decoration: InputDecoration(prefixText: '₦ ', hintText: '0', errorText: _amountProblem),
                            onChanged: (_) => setState(() {}),
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final n
                                  in _cat == BillCategory.airtime
                                      ? [100, 200, 500, 1000, 2000]
                                      : [2000, 5000, 10000, 20000])
                                ActionChip(
                                  label: Text(formatNaira(n * 100).replaceAll('.00', '')),
                                  onPressed: () => setState(() => _amount.text = '$n'),
                                ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                    child: PrimaryButton(
                      key: const Key('bill-continue'),
                      label: _chosenAmount == null ? 'Continue' : 'Pay ${formatNaira(_chosenAmount!)}',
                      onPressed: _ready ? _continue : null,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _ProviderGrid extends StatelessWidget {
  const _ProviderGrid({required this.billers, required this.selected, required this.onPick});

  final List<Biller> billers;
  final Biller? selected;
  final ValueChanged<Biller> onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final b in billers)
          InkWell(
            key: Key('biller-${b.id}'),
            borderRadius: BorderRadius.circular(16),
            onTap: () => onPick(b),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 100,
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: b == selected ? theme.colorScheme.primary : Colors.transparent, width: 1.5),
              ),
              child: Column(
                children: [
                  InitialsAvatar(text: b.name, size: 40),
                  const SizedBox(height: 6),
                  Text(b.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelMedium),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _PlanGrid extends StatelessWidget {
  const _PlanGrid({required this.plans, required this.selected, required this.onPick});

  final List<BillPlan> plans;
  final BillPlan? selected;
  final ValueChanged<BillPlan> onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        for (final p in plans)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: InkWell(
              key: Key('plan-${p.code}'),
              borderRadius: BorderRadius.circular(16),
              onTap: () => onPick(p),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: p == selected ? theme.colorScheme.primary : Colors.transparent, width: 1.5),
                ),
                child: Row(
                  children: [
                    Icon(
                      p == selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                      color: p == selected ? theme.colorScheme.primary : theme.colorScheme.outline,
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: Text(p.name, style: theme.textTheme.titleSmall)),
                    Text(formatNaira(p.amount), style: theme.textTheme.titleSmall),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
