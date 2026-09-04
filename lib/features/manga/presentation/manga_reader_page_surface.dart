import 'package:anime_tv/features/manga/application/manga_preferences_controller.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Tap navigation and local zoom for one finite-sized page or spread.
///
/// Give each logical page/layout its own key so a newly selected page starts at
/// 1x. The child owns its fit, padding, loading state, and background. Ordinary
/// single-finger drags at 1x are left to an enclosing PageView or ListView.
class MangaReaderPageSurface extends StatefulWidget {
  const MangaReaderPageSurface({
    required this.child,
    required this.preferences,
    required this.onToggleHud,
    required this.onTurnPage,
    this.onZoomChanged,
    this.resetToken = 0,
    super.key,
  });

  final Widget child;
  final MangaReaderPreferences preferences;
  final VoidCallback onToggleHud;

  /// Logical page delta: -1 is previous, +1 is next, regardless of direction.
  final ValueChanged<int> onTurnPage;

  /// True while zoomed or while an accepted pinch is still in progress.
  ///
  /// The owner can disable scroll physics while true. Reset the owner's lock
  /// when changing the active page/layout; disposing a page does not call back
  /// into a potentially disposing or rebuilding parent.
  final ValueChanged<bool>? onZoomChanged;

  /// Change to reset zoom without remounting the image/loading child subtree.
  /// The owner resets its scroll lock alongside this token; no callback fires
  /// during the update/build lifecycle.
  final int resetToken;

  @override
  State<MangaReaderPageSurface> createState() => _MangaReaderPageSurfaceState();
}

class _MangaReaderPageSurfaceState extends State<MangaReaderPageSurface> {
  final GlobalKey _viewportKey = GlobalKey();
  double _scale = 1;
  Offset _translation = Offset.zero;
  Offset _doubleTapPosition = Offset.zero;
  bool _interactionActive = false;
  bool _reportedZoomed = false;
  _PageZoomGestureRecognizer? _zoomRecognizer;

  bool get _zoomed => _scale > 1.001;

  @override
  void didUpdateWidget(covariant MangaReaderPageSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resetToken == widget.resetToken) return;
    _zoomRecognizer?.reset();
    _scale = 1;
    _translation = Offset.zero;
    _interactionActive = false;
    _reportedZoomed = false;
  }

  Size get _viewportSize {
    final renderObject = _viewportKey.currentContext?.findRenderObject();
    return renderObject is RenderBox && renderObject.hasSize
        ? renderObject.size
        : Size.zero;
  }

  void _notifyZoomChanged() {
    final zoomed = _zoomed || _interactionActive;
    if (zoomed == _reportedZoomed) return;
    _reportedZoomed = zoomed;
    widget.onZoomChanged?.call(zoomed);
  }

  Offset _boundedTranslation(Offset translation, double scale) {
    final size = _viewportSize;
    return Offset(
      translation.dx.clamp(size.width * (1 - scale), 0).toDouble(),
      translation.dy.clamp(size.height * (1 - scale), 0).toDouble(),
    );
  }

  void _updateTransform(
    Offset previousFocalPoint,
    Offset focalPoint,
    double scaleChange,
  ) {
    if (!scaleChange.isFinite || scaleChange <= 0) return;
    var nextScale = (_scale * scaleChange).clamp(1.0, 4.0);
    if (nextScale <= 1.001) nextScale = 1;
    final ratio = nextScale / _scale;
    final nextTranslation = _boundedTranslation(
      focalPoint - (previousFocalPoint - _translation) * ratio,
      nextScale,
    );
    setState(() {
      _scale = nextScale;
      _translation = nextTranslation;
    });
    _notifyZoomChanged();
  }

  void _doubleTap() {
    final nextScale = _zoomed ? 1.0 : 2.5;
    setState(() {
      _scale = nextScale;
      _translation = _boundedTranslation(
        _doubleTapPosition * (1 - nextScale),
        nextScale,
      );
    });
    _notifyZoomChanged();
  }

  void _tap(TapUpDetails details) {
    final preferences = widget.preferences;
    final width = _viewportSize.width;
    if (_zoomed || !preferences.tapZonesEnabled || width <= 0) {
      widget.onToggleHud();
      return;
    }

    final edgeFraction = preferences.tapZoneLayout == MangaTapZoneLayout.edges
        ? 0.2
        : 1 / 3;
    final position = details.localPosition.dx / width;
    if (position >= edgeFraction && position <= 1 - edgeFraction) {
      widget.onToggleHud();
      return;
    }

    var delta = position < edgeFraction ? -1 : 1;
    if (preferences.direction == MangaReadingDirection.rightToLeft) {
      delta = -delta;
    }
    if (preferences.invertTapZones) delta = -delta;
    widget.onTurnPage(delta);
  }

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: <Type, GestureRecognizerFactory>{
        _PageZoomGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<_PageZoomGestureRecognizer>(
              () => _zoomRecognizer = _PageZoomGestureRecognizer(
                debugOwner: this,
              ),
              (recognizer) {
                recognizer
                  ..gestureSettings = MediaQuery.maybeGestureSettingsOf(context)
                  ..canPan = (() => _zoomed)
                  ..onUpdate = _updateTransform
                  ..onInteractionChanged = (active) {
                    _interactionActive = active;
                    _notifyZoomChanged();
                  };
              },
            ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: _tap,
        onDoubleTapDown: widget.preferences.doubleTapZoom
            ? (details) => _doubleTapPosition = details.localPosition
            : null,
        onDoubleTap: widget.preferences.doubleTapZoom ? _doubleTap : null,
        child: ClipRect(
          key: _viewportKey,
          child: Transform(
            alignment: Alignment.topLeft,
            transform: Matrix4.identity()
              ..translateByDouble(_translation.dx, _translation.dy, 0, 1)
              ..scaleByDouble(_scale, _scale, 1, 1),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

typedef _ZoomUpdate =
    void Function(
      Offset previousFocalPoint,
      Offset focalPoint,
      double scaleChange,
    );

/// Joins the arena for a possible pinch, but never wins a 1x one-finger drag.
///
/// A normal ScaleGestureRecognizer also recognizes one-finger pan and competes
/// with a parent scrollable even when InteractiveViewer.panEnabled is false.
/// Here a second pointer accepts the pinch before either finger begins moving.
class _PageZoomGestureRecognizer extends OneSequenceGestureRecognizer {
  _PageZoomGestureRecognizer({super.debugOwner});

  bool Function()? canPan;
  _ZoomUpdate? onUpdate;
  ValueChanged<bool>? onInteractionChanged;
  final Map<int, Offset> _positions = <int, Offset>{};
  Offset? _initialPosition;
  bool _accepted = false;

  Offset get _focalPoint =>
      _positions.values.fold(Offset.zero, (sum, value) => sum + value) /
      _positions.length.toDouble();

  double _span(Offset focalPoint) => _positions.length < 2
      ? 0
      : _positions.values.fold<double>(
              0,
              (sum, value) => sum + (value - focalPoint).distance,
            ) /
            _positions.length;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    startTrackingPointer(event.pointer, event.transform);
    _positions[event.pointer] = event.localPosition;
    _initialPosition ??= event.localPosition;
    if (_positions.length >= 2 || _accepted) {
      _acceptInteraction();
    }
  }

  void _acceptInteraction() {
    final wasAccepted = _accepted;
    _accepted = true;
    resolve(GestureDisposition.accepted);
    if (!wasAccepted && _accepted) onInteractionChanged?.call(true);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (!_positions.containsKey(event.pointer)) return;
    if (event is PointerMoveEvent) {
      final previousFocalPoint = _focalPoint;
      final previousSpan = _span(previousFocalPoint);
      _positions[event.pointer] = event.localPosition;
      if (!_accepted) {
        final distance = (event.localPosition - _initialPosition!).distance;
        if (distance <= computeHitSlop(event.kind, gestureSettings)) return;
        if (!(canPan?.call() ?? false)) {
          resolve(GestureDisposition.rejected);
          return;
        }
        _acceptInteraction();
      }
      if (!_accepted || _positions.isEmpty) return;
      final focalPoint = _focalPoint;
      final span = _span(focalPoint);
      onUpdate?.call(
        previousFocalPoint,
        focalPoint,
        previousSpan > 0 && span > 0 ? span / previousSpan : 1,
      );
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _positions.remove(event.pointer);
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void rejectGesture(int pointer) {
    _positions.remove(pointer);
    stopTrackingPointer(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    final wasAccepted = _accepted;
    _accepted = false;
    _initialPosition = null;
    resolve(GestureDisposition.rejected);
    if (wasAccepted) onInteractionChanged?.call(false);
  }

  void reset() {
    _accepted = false;
    _initialPosition = null;
    for (final pointer in _positions.keys.toList()) {
      resolvePointer(pointer, GestureDisposition.rejected);
      _positions.remove(pointer);
      stopTrackingPointer(pointer);
    }
  }

  @override
  void dispose() {
    // Arena cleanup must not call back into an owner that is being disposed.
    onInteractionChanged = null;
    onUpdate = null;
    super.dispose();
  }

  @override
  String get debugDescription => 'manga page pinch or zoomed pan';
}

/// Image-only color adjustments. Every RGB corner stays in the 0..255 range.
/// Alpha is preserved; invalid numeric values fall back to a neutral amount.
List<double> mangaReaderColorMatrix(MangaReaderPreferences preferences) {
  final warmth = preferences.warmth.isFinite
      ? preferences.warmth.clamp(0.0, 1.0)
      : 0.0;
  final dim = preferences.dimAmount.isFinite
      ? preferences.dimAmount.clamp(0.0, 0.7)
      : 0.0;
  final dimFactor = 1 - dim;
  final factors = <double>[
    dimFactor,
    dimFactor * (1 - 0.08 * warmth),
    dimFactor * (1 - 0.30 * warmth),
  ];
  final sign = preferences.invertColors ? -1.0 : 1.0;
  const luminance = <double>[0.2126, 0.7152, 0.0722];
  final matrix = List<double>.filled(20, 0);
  for (var row = 0; row < 3; row += 1) {
    for (var column = 0; column < 3; column += 1) {
      final coefficient = preferences.grayscale
          ? luminance[column]
          : (row == column ? 1.0 : 0.0);
      matrix[row * 5 + column] = coefficient * sign * factors[row];
    }
    matrix[row * 5 + 4] = preferences.invertColors ? 255 * factors[row] : 0;
  }
  matrix[18] = 1;
  return List<double>.unmodifiable(matrix);
}

/// Wrap only a successfully decoded image, never its HUD/error/loading widgets.
class MangaReaderImageFilter extends StatelessWidget {
  const MangaReaderImageFilter({
    required this.preferences,
    required this.child,
    super.key,
  });

  final MangaReaderPreferences preferences;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!preferences.grayscale &&
        !preferences.invertColors &&
        (!preferences.warmth.isFinite || preferences.warmth <= 0) &&
        (!preferences.dimAmount.isFinite || preferences.dimAmount <= 0)) {
      return child;
    }
    return ColorFiltered(
      colorFilter: ColorFilter.matrix(mangaReaderColorMatrix(preferences)),
      child: child,
    );
  }
}
