import 'package:anime_tv/features/player/application/media3_platform_player.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

/// Media3 video/subtitle output only. TetoTV owns every control and gesture.
class Media3VideoSurface extends StatefulWidget {
  const Media3VideoSurface({
    required this.player,
    this.fit = BoxFit.contain,
    this.useSurfaceView = false,
    super.key,
  });
  final Media3PlatformPlayer player;
  final BoxFit fit;
  final bool useSurfaceView;

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
        child: ExcludeFocus(child: _buildPlatformView(snapshot.data!)),
      );
    },
  );

  Widget _buildPlatformView(int id) {
    const viewType = 'dev.tetotv/media3/video';
    final creationParams = {
      'id': id,
      'surfaceType': widget.useSurfaceView ? 'surface' : 'texture',
    };
    if (!widget.useSurfaceView) {
      // Preserve the current rendering path when the experimental mode is off.
      return AndroidView(
        key: ValueKey('media3-video-$id'),
        viewType: viewType,
        layoutDirection: TextDirection.ltr,
        creationParams: creationParams,
        creationParamsCodec: const StandardMessageCodec(),
      );
    }
    // A SurfaceView needs native hierarchy composition; putting it through the
    // default texture-backed AndroidView would defeat the separate video layer.
    // Do not enable any global Flutter renderer flag: MPV remains unchanged.
    return PlatformViewLink(
      key: ValueKey('media3-surface-video-$id'),
      viewType: viewType,
      surfaceFactory: (context, controller) => AndroidViewSurface(
        controller: controller as AndroidViewController,
        gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
        hitTestBehavior: PlatformViewHitTestBehavior.transparent,
      ),
      onCreatePlatformView: (params) =>
          PlatformViewsService.initExpensiveAndroidView(
              id: params.id,
              viewType: viewType,
              layoutDirection: TextDirection.ltr,
              creationParams: creationParams,
              creationParamsCodec: const StandardMessageCodec(),
              onFocus: () => params.onFocusChanged(true),
            )
            ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
            ..create(),
    );
  }
}
