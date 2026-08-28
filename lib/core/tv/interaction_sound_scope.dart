import 'package:flutter/widgets.dart';

/// Supplies the user-selected interaction sound policy to low-level TV
/// controls without coupling the reusable focus widget to Settings/Riverpod.
class InteractionSoundScope extends InheritedWidget {
  const InteractionSoundScope({
    required this.navigationEnabled,
    required this.clickEnabled,
    required super.child,
    super.key,
  });

  final bool navigationEnabled;
  final bool clickEnabled;

  static InteractionSoundScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<InteractionSoundScope>();

  @override
  bool updateShouldNotify(InteractionSoundScope oldWidget) =>
      navigationEnabled != oldWidget.navigationEnabled ||
      clickEnabled != oldWidget.clickEnabled;
}
