enum TrackingProvider {
  anilist(
    slug: 'anilist',
    displayName: 'AniList',
    tokenStorageKey: 'anilist_access_token',
    refreshTokenStorageKey: 'anilist_refresh_token',
    expiresAtStorageKey: 'anilist_token_expires_at',
  ),
  myAnimeList(
    slug: 'myanimelist',
    displayName: 'MAL',
    tokenStorageKey: 'myanimelist_access_token',
    refreshTokenStorageKey: 'myanimelist_refresh_token',
    expiresAtStorageKey: 'myanimelist_token_expires_at',
  );

  const TrackingProvider({
    required this.slug,
    required this.displayName,
    required this.tokenStorageKey,
    required this.refreshTokenStorageKey,
    required this.expiresAtStorageKey,
  });

  final String slug;
  final String displayName;
  final String tokenStorageKey;
  final String refreshTokenStorageKey;
  final String expiresAtStorageKey;
}
