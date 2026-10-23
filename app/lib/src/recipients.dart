import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'credentials.dart';

class Recipient {
  const Recipient({required this.bankCode, required this.accountNumber, required this.accountName});

  factory Recipient.fromJson(Map<String, dynamic> j) => Recipient(
    bankCode: j['bank_code'] as String,
    accountNumber: j['account_number'] as String,
    accountName: j['account_name'] as String,
  );

  final String bankCode;
  final String accountNumber;
  final String accountName;

  Map<String, dynamic> toJson() => {
    'bank_code': bankCode,
    'account_number': accountNumber,
    'account_name': accountName,
  };

  bool same(Recipient o) => o.bankCode == bankCode && o.accountNumber == accountNumber;
}

/// People this phone has sent to, newest first, so they can be paid again
/// in one tap. Kept on the device only.
class RecentRecipients extends ChangeNotifier {
  RecentRecipients._(this._store, this._items);

  static const _key = 'recent_recipients';
  static const max = 12;

  static Future<RecentRecipients> load(KeyValueStore store) async {
    final raw = await store.read(_key);
    var items = <Recipient>[];
    if (raw != null) {
      try {
        items = (jsonDecode(raw) as List).map((e) => Recipient.fromJson(e as Map<String, dynamic>)).toList();
      } on FormatException {
        // A damaged list is not worth failing over; start again.
      }
    }
    return RecentRecipients._(store, items);
  }

  final KeyValueStore _store;
  List<Recipient> _items;

  List<Recipient> get items => List.unmodifiable(_items);

  Future<void> add(Recipient r) async {
    _items = [r, ..._items.where((e) => !e.same(r))].take(max).toList();
    notifyListeners();
    await _store.write(_key, jsonEncode(_items.map((e) => e.toJson()).toList()));
  }

  Future<void> clear() async {
    _items = [];
    notifyListeners();
    await _store.delete(_key);
  }
}
