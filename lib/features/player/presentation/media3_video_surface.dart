import 'package:anime_tv/features/player/application/media3_platform_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Media3 video/subtitle output only. TetoTV owns every control and gesture.
class Media3VideoSurface extends StatefulWidget {
  const Media3VideoSurface({
    required this.player,
    this.fit = BoxFit.contain,
    super.key,
  });
  final Media3PlatformPlayer player;
  final BoxFit fit;

  @override
  State<Media3VideoSurface> createState() => _Media3VideoSurfaceState();
}

class _Media3VideoSurfaceState extends State<Media3VideoSurface> {
  @override
  void initState() {
    super.initState();
    _applyFit();
  }

  @override
  void didUpdateWidget(Media3VideoSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fit != widget.fit || oldWidget.player != widget.player) {
      _applyFit();
    }
  }

  Future<void> _applyFit() async {
    try {
      await widget.player.setOptions({
        'fit': switch (widget.fit) {
          BoxFit.cover => 'cover',
          BoxFit.fill => 'fill',
          _ => 'contain',
        },
      });
    } catch (_) {
      // Creation/open errors belong to the shared playback error UI.
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<int>(
    future: widget.player.ready,
    builder: (context, snapshot) {
      if (!snapshot.hasData) return const ColoredBox(color: Colors.black);
      return IgnorePointer(
        child: ExcludeFocus(
          child: AndroidView(
            key: ValueKey('media3-video-${snapshot.data}'),
            viewType: 'dev.tetotv/media3/video',
            layoutDirection: TextDirection.ltr,
            creationParams: {'id': snapshot.data},
            creationParamsCodec: const StandardMessageCodec(),
          ),
        ),
      );
    },
  );
}
