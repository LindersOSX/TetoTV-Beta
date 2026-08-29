import 'dart:convert';

/// Versioned self-attestation required before TetoTV starts a new Discord link.
///
/// Discord requires users to be at least 13, and some countries require an
/// older minimum age. TetoTV does not collect a birth date; it records only
/// this confirmation alongside the linked token.
class DiscordMinimumAgeConfirmation {
  const DiscordMinimumAgeConfirmation({
    required this.version,
    required this.confirmed,
  });

  const DiscordMinimumAgeConfirmation.current()
    : version = currentVersion,
      confirmed = true;

  static const currentVersion = 1;

  final int version;
  final bool confirmed;

  bool get isCurrentAndAccepted => version == currentVersion && confirmed;

  Map<String, Object> toJson() => {'version': version, 'confirmed': confirmed};

  String encodeForStorage() => jsonEncode(toJson());

  static DiscordMinimumAgeConfirmation parseExact(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException(
        'Discord minimum-age confirmation is missing.',
      );
    }
    const keys = {'version', 'confirmed'};
    if (value.length != keys.length ||
        value.keys.any((key) => !keys.contains(key))) {
      throw const FormatException(
        'Discord minimum-age confirmation is invalid.',
      );
    }
    final version = value['version'];
    final confirmed = value['confirmed'];
    if (version is! int || confirmed is! bool) {
      throw const FormatException(
        'Discord minimum-age confirmation is invalid.',
      );
    }
    final confirmation = DiscordMinimumAgeConfirmation(
      version: version,
      confirmed: confirmed,
    );
    if (!confirmation.isCurrentAndAccepted) {
      throw const FormatException(
        'Discord minimum-age confirmation is not accepted.',
      );
    }
    return confirmation;
  }

  static DiscordMinimumAgeConfirmation? decodeStored(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(value);
      return parseExact(decoded);
    } catch (_) {
      return null;
    }
  }
}
