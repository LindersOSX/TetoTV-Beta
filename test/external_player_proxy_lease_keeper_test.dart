import 'dart:async';

import 'package:anime_tv/features/player/application/external_player_proxy_lease_keeper.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

class _Lease implements PlaybackResourceLease {
  int closes = 0;
  bool _closed = false;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    closes++;
  }
}

class _BlockingLease implements PlaybackResourceLease {
  _BlockingLease(this.closeGate);

  final Completer<void> closeGate;
  int closes = 0;
  bool _closed = false;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    closes++;
    await closeGate.future;
  }
}

void main() {
  test(
    'retains only an owned proxy capability until external player returns',
    () async {
      final returns = StreamController<void>.broadcast();
      final owned = Uri.parse(
        'http://127.0.0.1:43121/tetotv-web/v1/'
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/'
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      );
      final lease = _Lease();
      final keeper = ExternalPlayerProxyLeaseKeeper(
        playerReturns: returns.stream,
        retainOwnedProxy: (uri) => uri == owned ? lease : null,
      );
      addTearDown(() async {
        await keeper.dispose();
        await returns.close();
      });

      expect(
        await keeper.retainForHandoff(Uri.parse('https://media.example/e.mp4')),
        isFalse,
      );
      expect(await keeper.retainForHandoff(owned), isTrue);
      expect(keeper.hasActiveLease, isTrue);

      returns.add(null);
      await Future<void>.delayed(Duration.zero);

      expect(keeper.hasActiveLease, isFalse);
      expect(lease.closes, 1);
    },
  );

  test('failed launch can revoke a retained capability immediately', () async {
    final returns = StreamController<void>.broadcast();
    final lease = _Lease();
    final keeper = ExternalPlayerProxyLeaseKeeper(
      playerReturns: returns.stream,
      retainOwnedProxy: (_) => lease,
    );
    addTearDown(() async {
      await keeper.dispose();
      await returns.close();
    });

    expect(
      await keeper.retainForHandoff(Uri.parse('http://127.0.0.1/a')),
      isTrue,
    );
    await keeper.release();

    expect(keeper.hasActiveLease, isFalse);
    expect(lease.closes, 1);
  });

  test(
    'return during lease replacement cannot report a revoked lease',
    () async {
      final returns = StreamController<void>.broadcast();
      final firstCloseGate = Completer<void>();
      final first = _BlockingLease(firstCloseGate);
      final second = _Lease();
      var retainCalls = 0;
      final keeper = ExternalPlayerProxyLeaseKeeper(
        playerReturns: returns.stream,
        retainOwnedProxy: (_) => retainCalls++ == 0 ? first : second,
      );
      addTearDown(() async {
        if (!firstCloseGate.isCompleted) firstCloseGate.complete();
        await keeper.dispose();
        await returns.close();
      });

      expect(
        await keeper.retainForHandoff(Uri.parse('http://127.0.0.1/first')),
        isTrue,
      );
      final replacement = keeper.retainForHandoff(
        Uri.parse('http://127.0.0.1/second'),
      );
      await Future<void>.delayed(Duration.zero);

      returns.add(null);
      await Future<void>.delayed(Duration.zero);
      firstCloseGate.complete();

      expect(await replacement, isFalse);
      expect(keeper.hasActiveLease, isFalse);
      expect(first.closes, 1);
      expect(second.closes, 1);
    },
  );
}
