import 'dart:async';

import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/features/catalog/domain/anime_trailer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class TrailerPlaybackRequest {
  const TrailerPlaybackRequest({required this.title, required this.trailer});

  final String title;
  final AnimeTrailer trailer;
}

class TrailerPlayerScreen extends StatefulWidget {
  const TrailerPlayerScreen({required this.request, super.key});

  static const routePath = '/trailer';

  final TrailerPlaybackRequest request;

  @override
  State<TrailerPlayerScreen> createState() => _TrailerPlayerScreenState();
}

class _TrailerPlayerScreenState extends State<TrailerPlayerScreen> {
  bool _opening = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_openTrailer());
    });
  }

  Future<void> _openTrailer() async {
    if (!_opening) setState(() => _opening = true);
    setState(() => _error = null);
    try {
      final opened = await AndroidTvBridge.instance.playInAppTrailer(
        provider: widget.request.trailer.provider.name,
        videoId: widget.request.trailer.videoId,
        title: widget.request.title,
      );
      if (!mounted) return;
      if (opened) {
        Navigator.of(context).maybePop();
        return;
      }
      setState(() {
        _opening = false;
        _error = 'This trailer could not be played on this device.';
      });
    } on PlatformException {
      if (!mounted) return;
      setState(() {
        _opening = false;
        _error = 'This trailer could not be played on this device.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _opening = false;
        _error = 'This trailer could not be played on this device.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        minimum: const EdgeInsets.all(28),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _error == null
                      ? Icons.play_circle_fill_rounded
                      : Icons.error_outline_rounded,
                  color: context.appPalette.accentBright,
                  size: 72,
                ),
                const SizedBox(height: 18),
                Text(
                  widget.request.title,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  _error ?? 'Opening trailer inside TetoTV…',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.appPalette.mutedText),
                ),
                const SizedBox(height: 24),
                if (_opening)
                  const CircularProgressIndicator()
                else
                  Wrap(
                    spacing: 12,
                    runSpacing: 10,
                    alignment: WrapAlignment.center,
                    children: [
                      FilledButton.icon(
                        autofocus: true,
                        onPressed: _openTrailer,
                        icon: const Icon(Icons.replay_rounded),
                        label: const Text('Try again'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(Icons.arrow_back_rounded),
                        label: const Text('Back'),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
