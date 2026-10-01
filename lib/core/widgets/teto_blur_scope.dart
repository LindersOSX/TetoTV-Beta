import 'package:flutter/widgets.dart';

/// The app-wide visual preference is inherited by pages and modal barriers.
/// Standalone widgets retain the enabled default without needing a provider.
class TetoBlurScope extends InheritedWidget {
  const TetoBlurScope({required this.enabled, required super.child, super.key});
  final bool enabled;
  static bool enabledOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TetoBlurScope>()?.enabled ??
      true;
  @override
  bool updateShouldNotify(TetoBlurScope oldWidget) =>
      enabled != oldWidget.enabled;
}
