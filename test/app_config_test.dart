import 'package:anime_tv/core/config/app_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('production companion services share the Wispbyte origin', () {
    expect(AppConfig.authBrokerBaseUrl, 'https://tetotv-bot.wisp.uno');
    expect(AppConfig.sourcePairingBrokerBaseUrl, 'https://tetotv-bot.wisp.uno');
    expect(AppConfig.sourcePairingBrokerBaseUrl, AppConfig.authBrokerBaseUrl);
    expect(AppConfig.crashReportBaseUrl, 'https://tetotv-bot.wisp.uno');
    expect(AppConfig.crashReportBaseUrl, AppConfig.sourcePairingBrokerBaseUrl);
    expect(AppConfig.diagnosticReportBaseUrl, 'https://tetotv-bot.wisp.uno');
    expect(AppConfig.diagnosticReportBaseUrl, AppConfig.crashReportBaseUrl);
    expect(AppConfig.watchTogetherBaseUrl, 'https://tetotv-bot.wisp.uno');
    expect(AppConfig.watchTogetherBaseUrl, AppConfig.diagnosticReportBaseUrl);
    expect(AppConfig.hasCrashReportEndpoint, isTrue);
    expect(AppConfig.hasDiagnosticReportEndpoint, isTrue);
    expect(AppConfig.hasWatchTogether, isTrue);
  });
}
