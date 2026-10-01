import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/theme/teto_box_style.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Compact episode entry shared by the browser's header controls.
class EpisodeNumberControl extends StatelessWidget {
  const EpisodeNumberControl({
    required this.episode,
    required this.total,
    required this.focusNode,
    required this.previousFocusNode,
    required this.nextFocusNode,
    required this.onChoose,
    required this.onPrevious,
    required this.onNext,
    required this.onExitDown,
    super.key,
  });
  final int episode;
  final int total;
  final FocusNode focusNode;
  final FocusNode previousFocusNode;
  final FocusNode nextFocusNode;
  final VoidCallback onChoose;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback onExitDown;

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.arrowDown) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent || event is KeyRepeatEvent) onExitDown();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('episode-selector-row'),
    decoration: TetoBoxStyle.translucentControlDecoration(context.appPalette),
    child: Row(
      children: [
        _step(context, previous: true),
        Expanded(
          child: Semantics(
            label: context.tr(
              'Episode {value1} of {value2}. Choose episode number',
              {'value1': episode, 'value2': total},
            ),
            button: true,
            onTap: onChoose,
            excludeSemantics: true,
            child: TvFocusable(
              key: const ValueKey('episode-manual-selector'),
              focusNode: focusNode,
              focusScale: 1,
              onPressed: onChoose,
              onKeyEvent: _key,
              child: SizedBox(
                height: 48,
                child: Center(
                  child: Text(
                    context.tr('Episode {value1} of {value2}', {
                      'value1': episode,
                      'value2': total,
                    }),
                    maxLines: 1,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: context.appPalette.primaryText,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        _step(context, previous: false),
      ],
    ),
  );

  Widget _step(BuildContext context, {required bool previous}) {
    final action = previous ? onPrevious : onNext;
    final content = SizedBox(
      width: 40,
      height: 48,
      child: Icon(
        previous ? Icons.chevron_left_rounded : Icons.chevron_right_rounded,
        color: context.appPalette.primaryText.withValues(
          alpha: action == null ? .32 : 1,
        ),
      ),
    );
    return Semantics(
      label: context.tr(previous ? 'Previous episode' : 'Next episode'),
      button: true,
      enabled: action != null,
      child: action == null
          ? content
          : TvFocusable(
              key: ValueKey(
                previous ? 'episode-step-previous' : 'episode-step-next',
              ),
              focusNode: previous ? previousFocusNode : nextFocusNode,
              focusScale: 1,
              onKeyEvent: _key,
              onPressed: action,
              child: content,
            ),
    );
  }
}
