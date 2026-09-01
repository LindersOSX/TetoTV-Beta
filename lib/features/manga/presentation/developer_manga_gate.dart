import 'package:anime_tv/features/settings/application/app_update_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Route-level Developer Mode guard for every Manga Preview surface.
///
/// Hiding the navigation icon is not authorization: typed route extras and
/// internal links can still outlive a settings change. This gate fails closed
/// until secure preferences finish loading and removes the child immediately
/// when Developer Mode is disabled.
class DeveloperMangaGate extends ConsumerWidget {
  const DeveloperMangaGate({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final update = ref.watch(appUpdateControllerProvider);
    if (!update.loaded) {
      return const Scaffold(
        key: ValueKey('manga-developer-gate-loading'),
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (!update.developerMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) GoRouter.maybeOf(context)?.go('/');
      });
      return const Scaffold(
        key: ValueKey('manga-developer-gate-closed'),
        body: Center(child: Text('Manga Preview requires Developer Mode.')),
      );
    }
    return child;
  }
}
