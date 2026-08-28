import 'dart:math' as math;

import 'package:flutter/material.dart';

const playerFailoverNoticeDuration = Duration(seconds: 4);

String sanitizePlayerFailoverReason(Object? reason, {int maxLength = 112}) {
  var value = reason?.toString().trim() ?? '';
  if (value.isEmpty) return 'The previous stream could not continue.';
  final lower = value.toLowerCase();
  if (lower.contains('no video frame') ||
      lower.contains('no first frame') ||
      lower.contains('were rendered')) {
    return 'No video frames were rendered.';
  }
  if (lower.contains('hls reference count') ||
      lower.contains('playlist') && lower.contains('too large')) {
    return 'The stream playlist was too complex for this player.';
  }
  if (lower.contains('mediacodec') ||
      lower.contains('video decoder') ||
      lower.contains('failed to decode') ||
      lower.contains('unsupported codec')) {
    return 'The stream was not compatible with this player.';
  }
  if (lower.contains('timed out') || lower.contains('timeout')) {
    return 'The previous stream timed out.';
  }
  if (RegExp(r'\b(?:401|403)\b').hasMatch(lower) ||
      lower.contains('forbidden') ||
      lower.contains('unauthorized')) {
    return 'The stream host rejected playback.';
  }
  if (RegExp(r'\b404\b').hasMatch(lower) || lower.contains('not found')) {
    return 'The previous stream was no longer available.';
  }
  if (lower.contains('socket') ||
      lower.contains('network') ||
      lower.contains('connection reset') ||
      lower.contains('host lookup')) {
    return 'The previous stream lost its network connection.';
  }

  value = value
      .replaceAll(RegExp(r'https?://\S+', caseSensitive: false), 'stream host')
      .replaceAll(
        RegExp(
          r'(?:authorization|bearer|cookie|password|secret|token)\s*[:=]\s*\S+',
          caseSensitive: false,
        ),
        'private value',
      )
      .replaceAll(RegExp(r'\b[a-f0-9]{32,}\b', caseSensitive: false), 'id')
      .replaceAll(RegExp(r'[\r\n\t]+'), ' ')
      .replaceFirst(
        RegExp(
          r'^(?:(?:bad state|stateerror|exception|formatexception)\s*:\s*)+',
          caseSensitive: false,
        ),
        '',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (value.isEmpty) return 'The previous stream could not continue.';
  if (value.length > maxLength) {
    value = '${value.substring(0, maxLength - 1).trimRight()}…';
  }
  if (!RegExp(r'[.!?…]$').hasMatch(value)) value = '$value.';
  return value;
}

String playerFailoverDestination({
  required bool isWebStream,
  String? providerName,
  String? quality,
}) {
  final safeProvider = providerName
      ?.replaceAll(RegExp(r'[^a-zA-Z0-9 ._+-]'), '')
      .trim();
  final safeQuality = quality
      ?.replaceAll(RegExp(r'[^a-zA-Z0-9 .+-]'), '')
      .trim();
  if (isWebStream) {
    if (safeProvider != null && safeProvider.isNotEmpty) {
      final bounded = safeProvider.length > 34
          ? '${safeProvider.substring(0, 33).trimRight()}…'
          : safeProvider;
      return '$bounded Web stream';
    }
    return 'another Web stream';
  }
  if (safeQuality != null && safeQuality.isNotEmpty) {
    return '$safeQuality Debrid stream';
  }
  return 'another Debrid stream';
}

String buildPlayerFailoverNotice({
  required String destination,
  required Object? reason,
}) {
  final safeDestination = destination
      .replaceAll(RegExp(r'[\r\n\t]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final target = safeDestination.isEmpty ? 'another stream' : safeDestination;
  return 'Stream switched to $target • ${sanitizePlayerFailoverReason(reason)}';
}

class PlayerFailoverNoticeGate {
  PlayerFailoverNoticeGate({
    this.deduplicationWindow = const Duration(seconds: 8),
  });

  final Duration deduplicationWindow;
  String? _lastMessage;
  DateTime? _lastShownAt;

  String? next({
    required String destination,
    required Object? reason,
    DateTime? now,
  }) {
    final message = buildPlayerFailoverNotice(
      destination: destination,
      reason: reason,
    );
    final timestamp = now ?? DateTime.now();
    final lastShownAt = _lastShownAt;
    if (_lastMessage == message &&
        lastShownAt != null &&
        timestamp.difference(lastShownAt) < deduplicationWindow) {
      return null;
    }
    _lastMessage = message;
    _lastShownAt = timestamp;
    return message;
  }
}

void showPlayerFailoverNotice(
  BuildContext context, {
  required PlayerFailoverNoticeGate gate,
  required String destination,
  required Object? reason,
}) {
  final message = gate.next(destination: destination, reason: reason);
  if (message == null) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final noticeWidth = math.max(
    120.0,
    math.min(620.0, MediaQuery.sizeOf(context).width - 32),
  );
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        duration: playerFailoverNoticeDuration,
        behavior: SnackBarBehavior.floating,
        width: noticeWidth,
        content: Text(message, maxLines: 2, overflow: TextOverflow.ellipsis),
      ),
    );
}
