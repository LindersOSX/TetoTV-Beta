import 'dart:convert';

import 'package:anime_tv/core/diagnostics/diagnostic_stack.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'JSON-escaped Unicode and controls stay inside the native queue budget',
    () {
      final stack = redactDiagnosticStack(
        List.filled(45, '\u0000界"\\' * 40).join('\n'),
      );
      expect(stack, isNot(contains('\u0000')));
      expect(stack.length, lessThanOrEqualTo(4000));
      expect(
        utf8.encode(jsonEncode(stack)).length - 2,
        lessThanOrEqualTo(8000),
      );
      expect(stack, contains('[stack truncated: report size limit]'));
    },
  );

  test(
    'compiled-in code lines survive layered redaction, private URIs do not',
    () {
      final stack = redactDiagnosticStack(
        '#0 Player.open (package:anime_tv/features/player/player.dart:42:8)\n'
        '#1 Zone.run (dart:async/zone.dart:20:3)\n'
        '#2 Plugin.open (package:private_customer/private_title.dart:50:4)\n'
        'https://private.example/video?token=secret-value\n'
        'Bearer secret-token',
      );
      final repeated = redactDiagnosticStack(stack);
      final exported = redactDiagnosticValue(repeated, maximum: 4000);
      expect(
        exported,
        contains(
          'package anime_tv/features/player/player.dart line=42 column=8',
        ),
      );
      expect(exported, contains('dart async/zone.dart line=20 column=3'));
      expect(repeated, stack);
      for (final private in [
        'private_customer',
        'private_title',
        'private.example',
        'secret-value',
        'secret-token',
      ]) {
        expect(exported, isNot(contains(private)));
      }
    },
  );

  test('arbitrary package locations and traversal are not exempted', () {
    final stack = redactDiagnosticStack(
      'package:anime_tv/private_customer.dart:42:8\n'
      '#0 x (package:anime_tv/../../private_customer.dart:42:8)',
    );
    expect(stack, isNot(contains('private_customer')));
  });

  test('oversized trace marks line, character and byte truncation', () {
    final lines = redactDiagnosticStack(
      List.filled(90, 'frame safe').join('\n'),
    );
    expect(lines, contains('[stack truncated: report size limit]'));
    final unicode = redactDiagnosticStack(
      List.filled(40, '界' * 110).join('\n'),
    );
    expect(unicode.length, lessThanOrEqualTo(4000));
    expect(utf8.encode(unicode).length, lessThanOrEqualTo(8000));
    expect(unicode, endsWith('[stack truncated: report size limit]'));
    expect(unicode, isNot(contains('\uFFFD')));
    expect(redactDiagnosticStack('x' * 500), contains('[line truncated]'));
  });

  test(
    'framework metadata has closed categories and never accepts context',
    () {
      expect(
        diagnosticErrorCategory(
          FlutterError('private text'),
          frameworkLibrary: 'rendering library',
        ),
        'error_type=flutter_error framework_area=rendering',
      );
      expect(
        diagnosticErrorCategory(
          StateError('customer title'),
          frameworkLibrary: 'private user@example.com',
        ),
        'error_type=state_error framework_area=other',
      );
    },
  );

  test('recoverable transport failures are warnings, not fatal crashes', () {
    for (final error in [
      "ClientException with SocketException: Failed host lookup: 's4.anilist.co' (OS Error: No address associated with hostname, errno = 7)",
      'ClientException: Software caused connection abort, uri=https://s4.anilist.co/file.jpg',
      'DioException [connection error]: Network is unreachable',
    ]) {
      expect(isRecoverableNetworkDiagnostic(error), isTrue);
      expect(diagnosticSeverityForGlobalError(error), 'warning');
    }
    expect(
      diagnosticSeverityForGlobalError(StateError('database invariant broke')),
      'fatal',
    );
  });
}
