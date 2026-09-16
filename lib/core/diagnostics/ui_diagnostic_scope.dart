import 'dart:ui' show FrameTiming;

import 'package:anime_tv/core/diagnostics/ui_diagnostic_context.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/widgets/tv_text_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Observes navigation without intercepting it. The local support recorder has
/// no upload consent responsibilities; the crash reporter controls delivery.
class UiDiagnosticScope extends StatefulWidget {
  const UiDiagnosticScope({
    required this.child,
    required this.routeInformation,
    this.languageSelection = false,
    this.languageCode = 'en',
    this.playerEngine = 'media3',
    this.media3SurfaceView = true,
    this.recorder,
    super.key,
  });

  final Widget child;
  final RouteInformationProvider routeInformation;
  final bool languageSelection;
  final String languageCode;
  final String playerEngine;
  final bool media3SurfaceView;
  final UiDiagnosticContext? recorder;

  @override
  State<UiDiagnosticScope> createState() => _UiDiagnosticScopeState();
}

class _UiDiagnosticScopeState extends State<UiDiagnosticScope>
    with WidgetsBindingObserver {
  final _ordinals = Expando<int>();
  int _nextOrdinal = 0;
  bool _sampleScheduled = false;
  bool _keyboardInsetVisible = false;
  UiDiagnosticContext get _recorder =>
      widget.recorder ?? UiDiagnosticContext.instance;

  @override
  void initState() {
    super.initState();
    widget.routeInformation.addListener(_routeChanged);
    FocusManager.instance.addListener(_focusChanged);
    HardwareKeyboard.instance.addHandler(_keyEvent);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addTimingsCallback(_timings);
    _routeChanged();
    _scheduleSample();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _viewport();
    _scheduleSample();
  }

  @override
  void didUpdateWidget(covariant UiDiagnosticScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.routeInformation != widget.routeInformation) {
      oldWidget.routeInformation.removeListener(_routeChanged);
      widget.routeInformation.addListener(_routeChanged);
    }
    _routeChanged();
    _scheduleSample();
  }

  @override
  void dispose() {
    widget.routeInformation.removeListener(_routeChanged);
    FocusManager.instance.removeListener(_focusChanged);
    HardwareKeyboard.instance.removeHandler(_keyEvent);
    WidgetsBinding.instance.removeObserver(this);
    WidgetsBinding.instance.removeTimingsCallback(_timings);
    super.dispose();
  }

  void _routeChanged() {
    if (!mounted) return;
    try {
      _recorder.configure(
        screen: widget.languageSelection
            ? 'language_selection'
            : UiDiagnosticContext.screenForUri(
                widget.routeInformation.value.uri,
              ),
        languageCode: widget.languageCode,
        playerEngine: widget.playerEngine,
        media3SurfaceView: widget.media3SurfaceView,
      );
    } catch (_) {
      // Diagnostics must never cause a secondary route/build exception.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    _recorder.recordLifecycle(state.name);
    if (state == AppLifecycleState.resumed) _scheduleSample();
  }

  @override
  void didChangeMetrics() {
    if (!mounted) return;
    _viewport();
    _scheduleSample();
  }

  void _viewport() {
    if (!mounted) return;
    try {
      final media = MediaQuery.maybeOf(context);
      final view = View.maybeOf(context);
      if (media == null || view == null) return;
      _keyboardInsetVisible = view.viewInsets.bottom > 0;
      _recorder.recordViewport(
        width: media.size.width,
        height: media.size.height,
        physicalWidth: view.physicalSize.width,
        physicalHeight: view.physicalSize.height,
        pixelRatio: view.devicePixelRatio,
        textScale: media.textScaler.scale(16) / 16,
      );
    } catch (_) {
      // An unavailable/disposed view is simply absent from the snapshot.
    }
  }

  void _timings(List<FrameTiming> timings) {
    if (!mounted) return;
    for (final timing in timings.skip(
      timings.length > 120 ? timings.length - 120 : 0,
    )) {
      _recorder.recordFrame(
        buildMs: timing.buildDuration.inMicroseconds / 1000,
        rasterMs: timing.rasterDuration.inMicroseconds / 1000,
      );
    }
  }

  /// Never inspect labels, keys, text, semantics or descendant widget dumps.
  /// A control inside any text-entry subtree is sensitive, including custom
  /// keyboard action keys (Back/Done/Clear) and native password fields.
  bool _sensitive(FocusNode? focus) {
    if (_keyboardInsetVisible) return true;
    final focusContext = focus?.context;
    if (focusContext == null) return false;
    try {
      bool sensitiveWidget(Widget widget) =>
          widget is TvKeyboardDialog ||
          widget is EditableText ||
          widget is TvTextInput;
      if (sensitiveWidget(focusContext.widget)) return true;
      var sensitive = false;
      var depth = 0;
      focusContext.visitAncestorElements((element) {
        if (sensitiveWidget(element.widget)) {
          sensitive = true;
          return false;
        }
        if (element.widget is UiDiagnosticScope) return false;
        // Fail closed on unusually deep/unavailable trees.
        if (++depth > 128) {
          sensitive = true;
          return false;
        }
        return true;
      });
      return sensitive;
    } catch (_) {
      return true;
    }
  }

  bool _refreshTextEntry() {
    final sensitive = _sensitive(FocusManager.instance.primaryFocus);
    _recorder.recordTextEntry(sensitive);
    return sensitive;
  }

  void _focusChanged() {
    if (!mounted) return;
    // Immediately remove geometry before scheduling an after-layout sample.
    _refreshTextEntry();
    _scheduleSample();
  }

  void _scheduleSample() {
    if (!mounted || _sampleScheduled) return;
    _sampleScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _sampleScheduled = false;
      if (mounted) _sampleFocus();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _sampleFocus() {
    if (_refreshTextEntry()) return;
    final focus = FocusManager.instance.primaryFocus;
    final focusContext = focus?.context;
    if (focus == null || focusContext == null) return;
    try {
      var control = UiDiagnosticContext.controlForLabel(focus.debugLabel);
      if (control == 'text_entry') {
        _recorder.recordTextEntry(true);
        return;
      }
      if (control == 'other') {
        focusContext.visitAncestorElements((element) {
          if (element.widget is TvFocusable) {
            control = 'button';
            return false;
          }
          return true;
        });
      }
      var ordinal = _ordinals[focus];
      if (ordinal == null) {
        _nextOrdinal = (_nextOrdinal + 1).clamp(1, 1000000);
        ordinal = _nextOrdinal;
        _ordinals[focus] = ordinal;
      }
      List<double>? rect;
      final render = focusContext.findRenderObject();
      if (render is RenderBox && render.attached && render.hasSize) {
        final origin = render.localToGlobal(Offset.zero);
        rect = [origin.dx, origin.dy, render.size.width, render.size.height];
      }
      final position = Scrollable.maybeOf(focusContext)?.position;
      _recorder.recordFocus(
        control: control,
        ordinal: ordinal,
        rect: rect,
        scrollOffset: position?.hasPixels == true ? position!.pixels : null,
        scrollMaximum: position?.hasContentDimensions == true
            ? position!.maxScrollExtent
            : null,
      );
    } catch (_) {
      // Layout may have been detached while a focus update was queued.
    }
  }

  bool _keyEvent(KeyEvent event) {
    if (!mounted) return false;
    try {
      if (_refreshTextEntry()) return false;
      if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
      // Never record printable characters or their count, even outside inputs.
      if (event.character?.isNotEmpty == true) return false;
      final key = event.logicalKey;
      final category = switch (key) {
        LogicalKeyboardKey.arrowUp => 'up',
        LogicalKeyboardKey.arrowDown => 'down',
        LogicalKeyboardKey.arrowLeft => 'left',
        LogicalKeyboardKey.arrowRight => 'right',
        LogicalKeyboardKey.enter ||
        LogicalKeyboardKey.numpadEnter ||
        LogicalKeyboardKey.select => 'activate',
        LogicalKeyboardKey.escape ||
        LogicalKeyboardKey.goBack ||
        LogicalKeyboardKey.browserBack => 'back',
        LogicalKeyboardKey.tab => 'tab',
        _ => null,
      };
      if (category != null) {
        _recorder.recordNavigation(category, repeat: event is KeyRepeatEvent);
        _scheduleSample();
      }
    } catch (_) {
      // Always let the app's real key handlers handle navigation.
    }
    return false;
  }

  bool _scrollNotification(ScrollNotification notification) {
    if (!mounted) return false;
    try {
      if (_refreshTextEntry()) return false;
      if (notification is ScrollEndNotification ||
          notification is UserScrollNotification) {
        final metrics = notification.metrics;
        _recorder.recordScroll(
          offset: metrics.pixels,
          maximum: metrics.maxScrollExtent,
          viewport: metrics.viewportDimension,
          horizontal: metrics.axis == Axis.horizontal,
        );
        _scheduleSample();
      }
    } catch (_) {
      // Observing support context never changes scrolling behavior.
    }
    return false;
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollNotification>(
        onNotification: _scrollNotification,
        child: widget.child,
      );
}
