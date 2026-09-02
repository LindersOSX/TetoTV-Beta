/// A retryable outage affecting the airing calendar after both its primary
/// catalog and read-only backup were unavailable.
///
/// This error deliberately carries no request URL, query, media identifier,
/// account data, or provider response. It is safe to show in the UI and retain
/// in the on-device diagnostic history.
final class AiringCalendarUnavailableException implements Exception {
  const AiringCalendarUnavailableException();

  static const message =
      'The airing calendar and its read-only backup are temporarily '
      'unavailable. Please try again shortly.';

  @override
  String toString() => message;
}
