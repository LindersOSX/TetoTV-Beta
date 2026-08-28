import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory secure storage whose next matching mutation can be failed.
///
/// Tests arm a failure after seeding an existing credential set. The failure
/// is consumed once so production rollback writes are allowed to complete.
class FailureInjectingSecureStorage extends Fake
    implements FlutterSecureStorage {
  FailureInjectingSecureStorage([Map<String, String> initialValues = const {}])
    : values = Map<String, String>.of(initialValues);

  final Map<String, String> values;
  final List<String> mutations = <String>[];

  String? _failingWriteKey;
  String? _failingDeleteKey;
  int _remainingFailures = 0;

  void failNextWrite(String key) {
    _failingWriteKey = key;
    _failingDeleteKey = null;
    _remainingFailures = 1;
  }

  void failNextDelete(String key) {
    _failingWriteKey = null;
    _failingDeleteKey = key;
    _remainingFailures = 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #read) {
      final key = invocation.namedArguments[#key] as String;
      return Future<String?>.value(values[key]);
    }
    if (invocation.memberName == #write) {
      final key = invocation.namedArguments[#key] as String;
      final value = invocation.namedArguments[#value] as String?;
      mutations.add('write:$key');
      if (_remainingFailures > 0 && key == _failingWriteKey) {
        _remainingFailures--;
        throw StateError('Injected secure-storage write failure.');
      }
      if (value == null) {
        values.remove(key);
      } else {
        values[key] = value;
      }
      return Future<void>.value();
    }
    if (invocation.memberName == #delete) {
      final key = invocation.namedArguments[#key] as String;
      mutations.add('delete:$key');
      if (_remainingFailures > 0 && key == _failingDeleteKey) {
        _remainingFailures--;
        throw StateError('Injected secure-storage delete failure.');
      }
      values.remove(key);
      return Future<void>.value();
    }
    if (invocation.memberName == #readAll) {
      return Future<Map<String, String>>.value(Map<String, String>.of(values));
    }
    if (invocation.memberName == #deleteAll) {
      values.clear();
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}
