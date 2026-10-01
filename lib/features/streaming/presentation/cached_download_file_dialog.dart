import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/theme/teto_box_style.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/widgets/teto_back_button.dart';
import 'package:anime_tv/features/streaming/data/debrid_account_history.dart';
import 'package:flutter/material.dart';

/// Confirm an exact cached file without implying a catalog episode match.
class CachedDownloadFileDialog extends StatelessWidget {
  const CachedDownloadFileDialog({
    required this.downloadName,
    required this.files,
    super.key,
  });

  final String downloadName;
  final List<DebridAccountVideoFile> files;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Dialog(
      shape: TetoBoxStyle.shape(palette),
      backgroundColor: TetoBoxStyle.fill(palette),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 720,
          maxHeight: MediaQuery.sizeOf(context).height * .85,
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: CustomScrollView(
            shrinkWrap: true,
            slivers: [
              SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        TetoBackButton(
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                context.tr('Choose a video file'),
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                downloadName,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: palette.mutedText),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      context.tr(
                        'Play any available file from this download. Manual playback does not update progress for the selected show.',
                      ),
                      style: TextStyle(color: palette.mutedText),
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.all(8),
                sliver: SliverList.builder(
                  itemCount: files.length,
                  itemBuilder: (context, index) {
                    final file = files[index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: TvFocusable(
                        key: ValueKey('cached-file:${file.id}'),
                        autofocus: index == 0,
                        onPressed: () => Navigator.of(context).pop(file),
                        borderRadius: BorderRadius.circular(
                          TetoBoxStyle.radius,
                        ),
                        child: Container(
                          decoration: TetoBoxStyle.decoration(palette),
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              Icon(
                                Icons.play_arrow_rounded,
                                color: palette.accentBright,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      file.name,
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: palette.primaryText,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    if (file.size > 0) ...[
                                      const SizedBox(height: 4),
                                      Text(
                                        file.size >= 1024 * 1024 * 1024
                                            ? '${(file.size / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB'
                                            : '${(file.size / (1024 * 1024)).toStringAsFixed(1)} MB',
                                        style: TextStyle(
                                          color: palette.mutedText,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
