import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/widgets/copyable_code_interaction.dart';
import 'package:anime_tv/features/auth/data/all_debrid_pin_auth_client.dart';
import 'package:anime_tv/features/auth/presentation/all_debrid_pairing_screen.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('AllDebrid PIN is exposed through the shared copy interaction', (
    tester,
  ) async {
    String? clipboardText;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardText = (call.arguments as Map)['text'] as String?;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.dark,
          home: AllDebridPairingScreen(client: _StaticAllDebridClient()),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('TETO'), findsOneWidget);
    expect(find.byType(CopyableCodeInteraction), findsOneWidget);
    await tester.tap(find.text('TETO'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(clipboardText, isNull);
    await tester.tap(find.text('TETO'));
    await tester.pump();

    expect(clipboardText, 'TETO');
    expect(find.text('AllDebrid PIN copied.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('polling 429 keeps the PIN active and honors Retry-After', (
    tester,
  ) async {
    final client = _StaticAllDebridClient(
      pollErrors: const [
        AllDebridPinAuthException(
          'AllDebrid asked TetoTV to slow down. Pairing will continue automatically.',
          httpStatus: 429,
          retryAfter: Duration(seconds: 12),
          isPollingDeferred: true,
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.dark,
          home: AllDebridPairingScreen(client: client),
        ),
      ),
    );
    await tester.pump();

    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(client.polls, 1);
    expect(find.text('TETO'), findsOneWidget);
    expect(find.text('Could not connect AllDebrid'), findsNothing);

    await tester.pump(const Duration(seconds: 11));
    expect(client.polls, 1);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(client.polls, 2);
    expect(find.textContaining('DioException'), findsNothing);
    expect(find.textContaining('429'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('unexpected Dio details never reach the AllDebrid error UI', (
    tester,
  ) async {
    final options = RequestOptions(
      path: 'https://alldebrid.test/private-device-path',
    );
    final client = _StaticAllDebridClient(
      startError: DioException(
        requestOptions: options,
        type: DioExceptionType.badResponse,
        response: Response<Map<String, dynamic>>(
          requestOptions: options,
          statusCode: 429,
          data: const {'error': 'private-provider-body'},
        ),
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.dark,
          home: AllDebridPairingScreen(client: client),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Could not connect AllDebrid'), findsOneWidget);
    expect(
      find.text('AllDebrid authorization could not be completed. Try again.'),
      findsOneWidget,
    );
    expect(find.textContaining('DioException'), findsNothing);
    expect(find.textContaining('private-provider-body'), findsNothing);
    expect(find.textContaining('private-device-path'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _StaticAllDebridClient extends AllDebridPinAuthClient {
  _StaticAllDebridClient({this.startError, List<Object> pollErrors = const []})
    : pollErrors = List<Object>.of(pollErrors);

  final Object? startError;
  final List<Object> pollErrors;
  int polls = 0;

  @override
  Future<AllDebridPinSession> start() async {
    if (startError case final error?) throw error;
    return AllDebridPinSession(
      pin: 'TETO',
      check: 'check-secret',
      verificationUrl: Uri.parse('https://alldebrid.com/pin/?pin=TETO'),
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
    );
  }

  @override
  Future<String?> poll(AllDebridPinSession session) async {
    polls++;
    if (pollErrors.isNotEmpty) throw pollErrors.removeAt(0);
    return null;
  }
}
