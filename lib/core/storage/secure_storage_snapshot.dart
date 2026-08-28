import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// An in-memory snapshot of a small, explicit set of encrypted-storage keys.
///
/// This is intentionally short lived and must never be serialized, logged, or
/// exposed to presentation state because its values can contain credentials.
final class SecureStorageSnapshot {
  SecureStorageSnapshot._(this._storage, this._values);

  final FlutterSecureStorage _storage;
  final Map<String, String?> _values;

  static Future<SecureStorageSnapshot> capture(
    FlutterSecureStorage storage,
    Iterable<String> keys,
  ) async {
    final values = <String, String?>{};
    for (final key in keys.toSet()) {
      values[key] = await storage.read(key: key);
    }
    return SecureStorageSnapshot._(storage, values);
  }

  /// Restores every key, continuing after an individual failure so rollback
  /// is best effort across the complete credential set.
  Future<void> restore() async {
    Object? firstError;
    StackTrace? firstStackTrace;
    for (final entry in _values.entries) {
      try {
        final value = entry.value;
        if (value == null) {
          await _storage.delete(key: entry.key);
        } else {
          await _storage.write(key: entry.key, value: value);
        }
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    if (firstError != null) {
      Error.throwWithStackTrace(
        const SecureStorageRollbackException(),
        firstStackTrace ?? StackTrace.current,
      );
    }
  }
}

final class SecureStorageRollbackException implements Exception {
  const SecureStorageRollbackException();

  @override
  String toString() => 'Encrypted credential rollback failed.';
}

/// Runs [operation] atomically with respect to the listed encrypted keys.
Future<T> runSecureStorageTransaction<T>(
  FlutterSecureStorage storage,
  Iterable<String> keys,
  Future<T> Function() operation,
) async {
  final snapshot = await SecureStorageSnapshot.capture(storage, keys);
  try {
    return await operation();
  } catch (error, stackTrace) {
    try {
      await snapshot.restore();
    } on SecureStorageRollbackException catch (rollbackError, rollbackStack) {
      Error.throwWithStackTrace(rollbackError, rollbackStack);
    }
    Error.throwWithStackTrace(error, stackTrace);
  }
}
