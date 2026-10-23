import 'dart:math';

final _random = Random.secure();

/// A random 128-bit hex id, used for device ids and idempotency keys.
String randomId() => List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
