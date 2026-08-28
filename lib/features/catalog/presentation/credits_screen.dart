import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/widgets/network_artwork.dart';
import 'package:anime_tv/features/catalog/application/catalog_providers.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class CreditsScreen extends ConsumerWidget {
  const CreditsScreen({required this.mediaId, super.key});
  final int mediaId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final details = ref.watch(animeDetailsProvider(mediaId));
    return Scaffold(
      backgroundColor: context.appPalette == AppThemePalette.defaults
          ? Colors.black
          : context.appPalette.background,
      body: SafeArea(
        minimum: const EdgeInsets.fromLTRB(34, 24, 34, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                TvFocusable(
                  key: const ValueKey('credits-back'),
                  autofocus: true,
                  onPressed: context.pop,
                  child: const Padding(
                    padding: EdgeInsets.all(10),
                    child: Icon(Icons.arrow_back_rounded),
                  ),
                ),
                const SizedBox(width: 14),
                Text(
                  'Cast & crew',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    details.asData?.value.title ?? '',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: context.appPalette.mutedText),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: details.when(
                loading: () => Center(
                  child: CircularProgressIndicator(
                    color: context.appPalette.accentBright,
                  ),
                ),
                error: (error, _) =>
                    Center(child: Text('Could not load credits: $error')),
                data: (anime) => _CreditsContent(anime: anime),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CreditsContent extends StatelessWidget {
  const _CreditsContent({required this.anime});

  final AnimeSummary anime;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (anime.studios.isNotEmpty) ...[
        Text(
          'STUDIOS',
          style: TextStyle(
            color: context.appPalette.accentBright,
            fontSize: 10,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 7),
        Wrap(
          spacing: 8,
          children: [
            for (final studio in anime.studios)
              _CreditChip(
                label: studio.name,
                icon: Icons.apartment_rounded,
                onPressed: () => context.push(
                  '/studio/${studio.id}?name=${Uri.encodeComponent(studio.name)}',
                ),
              ),
          ],
        ),
        const SizedBox(height: 18),
      ],
      Text(
        'CHARACTERS & ENGLISH CAST',
        style: TextStyle(
          color: context.appPalette.accentBright,
          fontSize: 10,
          fontWeight: FontWeight.w900,
        ),
      ),
      const SizedBox(height: 8),
      SizedBox(
        height: 126,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: anime.characters.length,
          separatorBuilder: (_, _) => const SizedBox(width: 9),
          itemBuilder: (context, index) =>
              _CharacterCard(character: anime.characters[index]),
        ),
      ),
      const SizedBox(height: 18),
      Text(
        'STAFF',
        style: TextStyle(
          color: context.appPalette.accentBright,
          fontSize: 10,
          fontWeight: FontWeight.w900,
        ),
      ),
      const SizedBox(height: 8),
      Expanded(
        child: GridView.builder(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 250,
            mainAxisExtent: 58,
            crossAxisSpacing: 9,
            mainAxisSpacing: 9,
          ),
          itemCount: anime.staff.length,
          itemBuilder: (context, index) {
            final person = anime.staff[index];
            return _PersonCard(
              person: person,
              onPressed: () => context.push(
                '/staff/${person.id}?name=${Uri.encodeComponent(person.name)}',
              ),
            );
          },
        ),
      ),
    ],
  );
}

class _CreditChip extends StatelessWidget {
  const _CreditChip({
    required this.label,
    required this.icon,
    required this.onPressed,
  });
  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => TvFocusable(
    onPressed: onPressed,
    borderRadius: BorderRadius.circular(8),
    child: Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: const Color(0xFF181818),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: context.appPalette.accentBright),
          const SizedBox(width: 7),
          Text(
            label,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
          ),
        ],
      ),
    ),
  );
}

class _PersonCard extends StatelessWidget {
  const _PersonCard({required this.person, required this.onPressed});
  final AnimePerson person;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => TvFocusable(
    onPressed: onPressed,
    borderRadius: BorderRadius.circular(7),
    child: ColoredBox(
      color: const Color(0xFF151515),
      child: Row(
        children: [
          SizedBox(
            width: 46,
            child: NetworkArtwork(url: person.imageUrl, cacheWidth: 100),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              person.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    ),
  );
}

class _CharacterCard extends StatelessWidget {
  const _CharacterCard({required this.character});
  final AnimeCharacter character;

  @override
  Widget build(BuildContext context) {
    final voice = character.voiceActor;
    final content = ColoredBox(
      color: const Color(0xFF151515),
      child: Row(
        children: [
          SizedBox(
            width: 74,
            child: NetworkArtwork(url: character.imageUrl, cacheWidth: 150),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  character.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  character.role ?? '',
                  style: TextStyle(
                    color: context.appPalette.accentBright,
                    fontSize: 9,
                  ),
                ),
                if (voice != null)
                  Text(
                    'EN: ${voice.name}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: context.appPalette.mutedText,
                      fontSize: 9,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    return SizedBox(
      width: 245,
      child: voice == null
          ? content
          : TvFocusable(
              onPressed: () => context.push(
                '/staff/${voice.id}?name=${Uri.encodeComponent(voice.name)}',
              ),
              borderRadius: BorderRadius.circular(7),
              child: content,
            ),
    );
  }
}
