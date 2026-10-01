import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// A fixed-size reading window for TV synopses. Only overflowing text moves;
/// the surrounding poster and controls never shift or take extra D-pad focus.
class AutoScrollingSynopsis extends StatefulWidget {
  const AutoScrollingSynopsis({
    required this.text,
    required this.maxLines,
    this.style,
    super.key,
  });

  final String text;
  final int maxLines;
  final TextStyle? style;

  @override
  State<AutoScrollingSynopsis> createState() => _AutoScrollingSynopsisState();
}

class _AutoScrollingSynopsisState extends State<AutoScrollingSynopsis>
    with WidgetsBindingObserver {
  static const _readingPause = Duration(seconds: 4);
  static const _pixelsPerSecond = 12.0;
  final _scroll = ScrollController();
  Timer? _pause;
  int _generation = 0;
  bool _running = false;
  bool _overflowing = false;
  bool _enabled = false;
  bool _layoutCheckScheduled = false;
  bool _foreground = true;
  bool _returnToStart = false;
  bool _userScrolling = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
  }

  @override
  void didUpdateWidget(AutoScrollingSynopsis oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.style != widget.style ||
        oldWidget.maxLines != widget.maxLines) {
      _stop();
      _returnToStart = true;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _reconcile();
  }

  void _stop({bool cancelAnimation = true}) {
    final wasRunning = _running;
    _generation++;
    _pause?.cancel();
    _pause = null;
    _running = false;
    if (wasRunning && cancelAnimation && _scroll.hasClients) {
      _scroll.jumpTo(_scroll.offset);
    }
  }

  void _afterLayout() {
    if (_layoutCheckScheduled) return;
    _layoutCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _layoutCheckScheduled = false;
      if (!mounted) return;
      if (_returnToStart && _scroll.hasClients) {
        _scroll.jumpTo(0);
        _returnToStart = false;
      }
      _reconcile();
    });
  }

  void _reconcile() {
    if (!mounted) return;
    if (_userScrolling) return;
    if (!_enabled || !_foreground || !_overflowing) {
      _stop();
      return;
    }
    if (_running ||
        _pause != null ||
        !_scroll.hasClients ||
        !_scroll.position.hasContentDimensions ||
        _scroll.position.maxScrollExtent <= 1) {
      return;
    }
    final generation = _generation;
    _pause = Timer(_readingPause, () async {
      _pause = null;
      if (!mounted || generation != _generation || !_scroll.hasClients) return;
      _running = true;
      final end = _scroll.position.maxScrollExtent;
      if (_scroll.offset >= end - 1) {
        // Start the next reading pass without slowly rewinding the paragraph.
        _scroll.jumpTo(0);
      } else {
        final milliseconds = ((end - _scroll.offset) / _pixelsPerSecond * 1000)
            .ceil()
            .clamp(1, 3600000);
        await _scroll.animateTo(
          end,
          duration: Duration(milliseconds: milliseconds),
          curve: Curves.linear,
        );
      }
      if (!mounted || generation != _generation) return;
      _running = false;
      _reconcile();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _generation++;
    _pause?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    _enabled =
        !media.disableAnimations &&
        !media.accessibleNavigation &&
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true);
    final style = DefaultTextStyle.of(context).style.merge(widget.style);
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          textDirection: Directionality.of(context),
          textScaler: media.textScaler,
          locale: Localizations.maybeLocaleOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        final lines = painter.computeLineMetrics();
        final visibleHeight = lines
            .take(math.max(1, widget.maxLines))
            .fold<double>(0, (sum, line) => sum + line.height);
        final height = math.min(visibleHeight, constraints.maxHeight);
        _overflowing = painter.height > height + 1;
        painter.dispose();
        _afterLayout();
        return SizedBox(
          height: height,
          child: NotificationListener<UserScrollNotification>(
            onNotification: (notification) {
              // Touch/trackpad reading remains available, including reduced
              // motion. Resume auto reading only after another quiet pause.
              _userScrolling = notification.direction != ScrollDirection.idle;
              // The gesture already interrupted automatic animation; do not
              // cancel the user's drag by jumping its scroll position.
              _stop(cancelAnimation: false);
              _reconcile();
              return false;
            },
            child: SingleChildScrollView(
              key: const ValueKey('anime-details-synopsis-scroll'),
              controller: _scroll,
              primary: false,
              child: Text(widget.text, style: style),
            ),
          ),
        );
      },
    );
  }
}
