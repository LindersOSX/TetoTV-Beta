package dev.animetv.anime_tv

import java.util.Locale

internal const val DIRECT_TORRENT_MAX_FILE_BYTES = 6L * 1024L * 1024L * 1024L
internal const val DIRECT_TORRENT_MIN_FREE_RESERVE_BYTES = 256L * 1024L * 1024L
internal const val DIRECT_TORRENT_MAX_FILE_COUNT = 5_000
internal const val DIRECT_TORRENT_ARM32_MAX_PAGE_SIZE_BYTES = 16_384L
internal const val DIRECT_TORRENT_MAX_SELECTED_BASENAME_CHARS = 512

/**
 * Both pinned ARM artifacts are 16 KiB ELF-aligned. Keep the explicit ARM32
 * page-size guard so an unexpected future runtime cannot load an incompatible
 * native torrent engine.
 */
internal fun supportsDirectTorrentRuntime(
    processIs64Bit: Boolean,
    supportedAbis: List<String>,
    pageSizeBytes: Long,
): Boolean {
    if (processIs64Bit) return "arm64-v8a" in supportedAbis
    return "armeabi-v7a" in supportedAbis &&
        pageSizeBytes in 1L..DIRECT_TORRENT_ARM32_MAX_PAGE_SIZE_BYTES
}

internal data class DirectTorrentFileCandidate(
    val index: Int,
    val relativePath: String,
    val size: Long,
    val isPadFile: Boolean = false,
)

internal data class DirectTorrentByteRange(
    val start: Long,
    val endInclusive: Long,
) {
    val length: Long get() = endInclusive - start + 1L
}

internal class DirectTorrentRangeException : IllegalArgumentException()

private enum class NativeEpisodeIdentityVerdict {
    MATCH,
    MISMATCH,
    UNKNOWN,
}

private enum class NativeEpisodeMatchKind {
    SEASON_RELATIVE,
    ABSOLUTE,
}

private data class NativeEpisodeIdentityAssessment(
    val verdict: NativeEpisodeIdentityVerdict,
    val strength: Int = 0,
    val exact: Boolean = false,
    val matchKind: NativeEpisodeMatchKind? = null,
)

private data class NativeEpisodeSpan(
    val first: Int,
    val last: Int,
    val season: Int? = null,
    val explicit: Boolean = false,
    val isSpecial: Boolean = false,
) {
    fun contains(episode: Int): Boolean = episode in first..last
}

/** Pure, unit-testable policy kept separate from the native torrent session. */
internal object DirectTorrentPolicy {
    private val videoExtensions = setOf(
        "mkv",
        "mp4",
        "m4v",
        "webm",
        "avi",
        "mov",
        "ts",
        "m2ts",
    )

    fun isVideoPath(path: String): Boolean {
        val extension = path.substringAfterLast('.', missingDelimiterValue = "")
            .lowercase(Locale.ROOT)
        return extension in videoExtensions
    }

    fun isSelectableVideo(file: DirectTorrentFileCandidate): Boolean =
        !file.isPadFile &&
            file.size > 0L &&
            file.size <= DIRECT_TORRENT_MAX_FILE_BYTES &&
            isVideoPath(file.relativePath)

    fun chooseVideoFile(
        files: List<DirectTorrentFileCandidate>,
        episode: Int?,
        preferredFileIndex: Int?,
        requestedSeason: Int? = null,
        requestedAbsoluteEpisode: Int? = null,
        requestedSpecial: Boolean = false,
        allowSeasonRelativeBare: Boolean = false,
        requireNumberingSchemeEvidence: Boolean = false,
    ): DirectTorrentFileCandidate? {
        val playable = files.filter(::isSelectableVideo)
        val preferred = preferredFileIndex?.let { index ->
            playable.firstOrNull { it.index == index }
        }
        if (episode == null || episode <= 0) {
            return preferred ?: playable.maxByOrNull { it.size }
        }

        val assessments = playable.associateWith { file ->
            assessEpisodeIdentity(
                // Preserve season folders such as `Season 2/01.mkv` as
                // identity evidence. Only the basename crosses back to Dart.
                label = file.relativePath,
                requestedEpisode = episode,
                requestedSeason = requestedSeason,
                requestedAbsoluteEpisode = requestedAbsoluteEpisode,
                requestedSpecial = requestedSpecial,
                allowSeasonRelativeBare = allowSeasonRelativeBare,
                requireNumberingSchemeEvidence = requireNumberingSchemeEvidence,
            )
        }
        val matched = playable.filter { file ->
            assessments[file]?.let { assessment ->
                assessment.verdict == NativeEpisodeIdentityVerdict.MATCH && assessment.exact
            } == true
        }
        if (matched.isEmpty()) {
            // Ranges, opaque names, extras, and confirmed wrong episodes all
            // fail closed. A provider index only breaks a verified tie.
            return null
        }
        val matchKinds = matched.mapNotNull { assessments[it]?.matchKind }.toSet()
        if (
            NativeEpisodeMatchKind.SEASON_RELATIVE in matchKinds &&
            NativeEpisodeMatchKind.ABSOLUTE in matchKinds
        ) {
            return null
        }
        preferred?.takeIf { it in matched }?.let { return it }
        return matched.maxWithOrNull(
            compareBy<DirectTorrentFileCandidate> { file ->
                assessments[file]?.strength ?: 0
            }.thenBy { file ->
                val lower = file.relativePath.lowercase(Locale.ROOT)
                if ("sample" in lower || "creditless" in lower) 0 else 1
            }.thenBy { it.size },
        )
    }

    /**
     * Mirrors the Dart playback identity guard without retaining a filename.
     * Generic digit delimiters are deliberately not used: values such as
     * 5.1-channel audio, 10-bit video, resolutions, and years are not episode
     * evidence.
     */
    private fun assessEpisodeIdentity(
        label: String,
        requestedEpisode: Int,
        requestedSeason: Int?,
        requestedAbsoluteEpisode: Int?,
        requestedSpecial: Boolean,
        allowSeasonRelativeBare: Boolean,
        requireNumberingSchemeEvidence: Boolean,
    ): NativeEpisodeIdentityAssessment {
        if (requestedEpisode <= 0 || label.isBlank()) {
            return NativeEpisodeIdentityAssessment(NativeEpisodeIdentityVerdict.UNKNOWN)
        }
        val spans = episodeSpans(label)
        val labelSeason = explicitSeasonNumber(label)
        if (
            requestedSeason != null &&
            labelSeason != null &&
            requestedSeason != labelSeason &&
            spans.isEmpty()
        ) {
            return NativeEpisodeIdentityAssessment(NativeEpisodeIdentityVerdict.MISMATCH)
        }
        if (spans.isEmpty()) {
            return NativeEpisodeIdentityAssessment(NativeEpisodeIdentityVerdict.UNKNOWN)
        }

        var episodeWasPresentInDifferentSeason = false
        var bareNumberingWasAmbiguous = false
        val matching = mutableListOf<NativeEpisodeSpan>()
        var matchedAbsolute = false
        for (span in spans) {
            if (span.isSpecial && !requestedSpecial) continue
            val observedSeason = span.season ?: labelSeason
            if (
                requestedSeason != null &&
                observedSeason != null &&
                observedSeason != requestedSeason
            ) {
                if (
                    span.contains(requestedEpisode) ||
                    (requestedAbsoluteEpisode != null && span.contains(requestedAbsoluteEpisode))
                ) {
                    episodeWasPresentInDifferentSeason = true
                }
                continue
            }

            val isBare = observedSeason == null
            val absoluteEpisode = requestedAbsoluteEpisode
            if (
                isBare &&
                    absoluteEpisode == null &&
                    (requireNumberingSchemeEvidence || hasUnresolvedSequelHint(label))
            ) {
                bareNumberingWasAmbiguous = true
                continue
            }
            if (
                isBare &&
                    absoluteEpisode != null &&
                    absoluteEpisode != requestedEpisode
            ) {
                if (span.contains(absoluteEpisode)) {
                    matching += span
                    matchedAbsolute = true
                } else if (span.contains(requestedEpisode)) {
                    if (allowSeasonRelativeBare) {
                        matching += span
                    } else {
                        bareNumberingWasAmbiguous = true
                    }
                }
                continue
            }
            val laterSeasonBare = isBare && requestedSeason != null && requestedSeason > 1
            if (laterSeasonBare) {
                if (requestedAbsoluteEpisode == null) {
                    if (allowSeasonRelativeBare && span.contains(requestedEpisode)) {
                        matching += span
                    } else {
                        bareNumberingWasAmbiguous = true
                    }
                    continue
                }
                if (span.contains(requestedEpisode)) {
                    if (allowSeasonRelativeBare) {
                        matching += span
                    } else {
                        bareNumberingWasAmbiguous = true
                    }
                }
                continue
            }
            if (span.contains(requestedEpisode)) matching += span
        }
        if (matching.isNotEmpty()) {
            val multipleIdentities = spans.any { it !in matching }
            val range = matching.any { it.first != it.last } || multipleIdentities
            return NativeEpisodeIdentityAssessment(
                NativeEpisodeIdentityVerdict.MATCH,
                strength = when {
                    matching.any { it.season != null } -> 4
                    matching.any { it.explicit } -> 3
                    else -> 2
                },
                exact = !range,
                matchKind = if (matchedAbsolute) {
                    NativeEpisodeMatchKind.ABSOLUTE
                } else {
                    NativeEpisodeMatchKind.SEASON_RELATIVE
                },
            )
        }
        if (bareNumberingWasAmbiguous) {
            return NativeEpisodeIdentityAssessment(NativeEpisodeIdentityVerdict.UNKNOWN)
        }
        if (episodeWasPresentInDifferentSeason) {
            return NativeEpisodeIdentityAssessment(NativeEpisodeIdentityVerdict.MISMATCH)
        }
        return NativeEpisodeIdentityAssessment(NativeEpisodeIdentityVerdict.MISMATCH)
    }

    private fun episodeSpans(value: String): List<NativeEpisodeSpan> {
        val spans = mutableListOf<NativeEpisodeSpan>()
        val occupied = mutableListOf<IntRange>()

        fun collect(
            expression: Regex,
            read: (MatchResult) -> NativeEpisodeSpan?,
        ) {
            expression.findAll(value).forEach { match ->
                val range = match.range
                if (occupied.any { existing ->
                        range.first <= existing.last && existing.first <= range.last
                    }
                ) {
                    return@forEach
                }
                val span = read(match) ?: return@forEach
                spans += span
                occupied += range
            }
        }

        collect(
            Regex(
                """\b(?:specials?|sp|ova|ona|oad)\s*[:#._ -]*0*(\d{1,4})(?:v\d+)?(?:\s*[-~]\s*(?:(?:specials?|sp|ova|ona|oad)\s*)?0*(\d{1,4}))?\b""",
                RegexOption.IGNORE_CASE,
            ),
        ) { match ->
            episodeSpan(
                match.groupValues.getOrNull(1),
                match.groupValues.getOrNull(2),
                season = 0,
                explicit = true,
                isSpecial = true,
            )
        }
        collect(
            Regex(
                """\bs(?:eason\s*)?0*(\d{1,3})\s*[._ -]*e(?:p(?:isode)?)?\s*0*(\d{1,4})(?:v\d+)?(?:\s*[-~]\s*(?:(?:s0*\d{1,3}\s*)?e(?:p(?:isode)?)?\s*)?0*(\d{1,4}))?""",
                RegexOption.IGNORE_CASE,
            ),
        ) { match ->
            episodeSpan(
                match.groupValues.getOrNull(2),
                match.groupValues.getOrNull(3),
                season = seasonInt(match.groupValues.getOrNull(1)),
                explicit = true,
            )
        }
        collect(
            Regex(
                """\bseason\s*0*(\d{1,3})\s*[._ -]*(?:episode|ep)\s*[:#._ -]*0*(\d{1,4})(?:v\d+)?(?:\s*[-~]\s*0*(\d{1,4}))?""",
                RegexOption.IGNORE_CASE,
            ),
        ) { match ->
            episodeSpan(
                match.groupValues.getOrNull(2),
                match.groupValues.getOrNull(3),
                season = seasonInt(match.groupValues.getOrNull(1)),
                explicit = true,
            )
        }
        collect(
            Regex(
                """\b0*(\d{1,3})x0*(\d{1,4})(?:v\d+)?(?:\s*[-~]\s*0*(\d{1,4}))?\b""",
                RegexOption.IGNORE_CASE,
            ),
        ) { match ->
            episodeSpan(
                match.groupValues.getOrNull(2),
                match.groupValues.getOrNull(3),
                season = seasonInt(match.groupValues.getOrNull(1)),
                explicit = true,
            )
        }
        collect(
            Regex(
                """\b(?:episodes?|eps?|ep)\s*[:#._ -]*0*(\d{1,4})(?:v\d+)?(?:\s*[-~]\s*(?:(?:episodes?|eps?|ep)\s*)?0*(\d{1,4}))?""",
                RegexOption.IGNORE_CASE,
            ),
        ) { match ->
            episodeSpan(
                match.groupValues.getOrNull(1),
                match.groupValues.getOrNull(2),
                explicit = true,
            )
        }
        collect(
            Regex(
                """\be\s*[:#._ -]*0*(\d{1,4})(?:v\d+)?(?:\s*[-~]\s*e?\s*0*(\d{1,4}))?\b""",
                RegexOption.IGNORE_CASE,
            ),
        ) { match ->
            episodeSpan(
                match.groupValues.getOrNull(1),
                match.groupValues.getOrNull(2),
                explicit = true,
            )
        }
        collect(
            Regex(
                """\s[-–—]\s+0*(\d{1,4})(?:v\d+)?(?:\s*[-~]\s*0*(\d{1,4}))?\b(?!\.\d)(?!\s*(?:-\s*)?(?:bits?|ch(?:annels?)?|fps|hz)\b)""",
                RegexOption.IGNORE_CASE,
            ),
        ) { match ->
            episodeSpan(
                match.groupValues.getOrNull(1),
                match.groupValues.getOrNull(2),
            )
        }
        collect(
            Regex(
                """[\[(]\s*0*(\d{1,4})(?:v\d+)?(?:\s*[-~]\s*0*(\d{1,4}))?(?=\s*[\])])""",
                RegexOption.IGNORE_CASE,
            ),
        ) { match ->
            episodeSpan(
                match.groupValues.getOrNull(1),
                match.groupValues.getOrNull(2),
            )
        }
        collect(
            Regex(
                """(?:^|[\\/])\s*0*(\d{1,4})(?:v\d+)?(?=\.(?:mkv|mp4|m4v|webm|avi|mov|ts|m2ts)\s*$)""",
                RegexOption.IGNORE_CASE,
            ),
        ) { match -> episodeSpan(match.groupValues.getOrNull(1), null) }
        return spans
    }

    private fun episodeSpan(
        firstValue: String?,
        lastValue: String?,
        season: Int? = null,
        explicit: Boolean = false,
        isSpecial: Boolean = false,
    ): NativeEpisodeSpan? {
        val parsedFirst = positiveInt(firstValue)
        val parsedLast = positiveInt(lastValue)
        if (!plausibleEpisode(parsedFirst, explicit)) return null
        val first = parsedFirst ?: return null
        val last = parsedLast ?: first
        if (!plausibleEpisode(last, explicit)) return null
        return NativeEpisodeSpan(
            first = minOf(first, last),
            last = maxOf(first, last),
            season = season,
            explicit = explicit,
            isSpecial = isSpecial || season == 0,
        )
    }

    private fun plausibleEpisode(value: Int?, explicit: Boolean): Boolean {
        if (value == null || value <= 0 || value > if (explicit) 9_999 else 1_500) {
            return false
        }
        if (explicit) return true
        if (value in 1_900..2_100) return false
        return value !in setOf(240, 360, 480, 540, 576, 720, 1_080, 1_440)
    }

    private fun explicitSeasonNumber(value: String): Int? {
        val expressions = listOf(
            Regex("""\bseason\s*0*(\d{1,3})\b""", RegexOption.IGNORE_CASE),
            Regex("""\b0*(\d{1,3})(?:st|nd|rd|th)\s+season\b""", RegexOption.IGNORE_CASE),
            Regex("""\bs0*(\d{1,3})(?=\s*e\d|\b)""", RegexOption.IGNORE_CASE),
            Regex("""\b0*(\d{1,3})x\d{1,4}\b""", RegexOption.IGNORE_CASE),
        )
        for (expression in expressions) {
            val parsed = seasonInt(expression.find(value)?.groupValues?.getOrNull(1))
            if (parsed != null) return parsed
        }
        return null
    }

    private fun hasUnresolvedSequelHint(value: String): Boolean {
        if (
            Regex(
                """\b(?:the\s+)?final\s+season\b""",
                RegexOption.IGNORE_CASE,
            ).containsMatchIn(value)
        ) {
            return true
        }
        if (
            Regex(
                """\b(?:second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth)\s+season\b""",
                RegexOption.IGNORE_CASE,
            ).containsMatchIn(value)
        ) {
            return true
        }
        val part = Regex(
            """\b(?:part|cour)\s*(\d{1,3}|ii|iii|iv|v|vi|vii|viii|ix|x)\b""",
            RegexOption.IGNORE_CASE,
        ).find(value)?.groupValues?.getOrNull(1)?.lowercase(Locale.ROOT)
        val partNumber = part?.toIntOrNull() ?: mapOf(
            "ii" to 2,
            "iii" to 3,
            "iv" to 4,
            "v" to 5,
            "vi" to 6,
            "vii" to 7,
            "viii" to 8,
            "ix" to 9,
            "x" to 10,
        )[part]
        if (partNumber != null && partNumber > 1) return true
        return Regex(
            """\b(?:ii|iii|iv|v|vi|vii|viii|ix|x)\s*$""",
            RegexOption.IGNORE_CASE,
        ).containsMatchIn(value.trim())
    }

    private fun positiveInt(value: String?): Int? =
        value?.takeIf { it.isNotEmpty() }?.toIntOrNull()?.takeIf { it > 0 }

    private fun seasonInt(value: String?): Int? =
        value?.takeIf { it.isNotEmpty() }?.toIntOrNull()?.takeIf { it >= 0 }

    /**
     * Returns only the selected file's basename for the in-memory Dart
     * handoff. Directory names never cross the platform channel, control
     * characters are removed, and malicious metadata cannot create an
     * unbounded channel value.
     */
    fun selectedBasename(path: String): String {
        val basename = path
            .substringAfterLast('/')
            .substringAfterLast('\\')
            .filterNot(Char::isISOControl)
            .trim()
        if (basename.length <= DIRECT_TORRENT_MAX_SELECTED_BASENAME_CHARS) return basename
        val tailLength = DIRECT_TORRENT_MAX_SELECTED_BASENAME_CHARS / 2
        val headLength = DIRECT_TORRENT_MAX_SELECTED_BASENAME_CHARS - tailLength - 1
        return basename.take(headLength) + "…" + basename.takeLast(tailLength)
    }

    /**
     * Parses one RFC 7233 byte range. Multi-range responses are intentionally
     * rejected because MPV only needs a single seek range and multipart output
     * would increase the attack surface of the loopback server.
     */
    fun parseRange(header: String?, totalLength: Long): DirectTorrentByteRange? {
        if (header == null) return null
        if (totalLength <= 0L || header.length > 200 || ',' in header) {
            throw DirectTorrentRangeException()
        }
        val match = Regex("^bytes=(\\d*)-(\\d*)$", RegexOption.IGNORE_CASE)
            .matchEntire(header.trim()) ?: throw DirectTorrentRangeException()
        val first = match.groupValues[1]
        val last = match.groupValues[2]
        if (first.isEmpty() && last.isEmpty()) throw DirectTorrentRangeException()

        if (first.isEmpty()) {
            val suffixLength = last.toLongOrNull() ?: throw DirectTorrentRangeException()
            if (suffixLength <= 0L) throw DirectTorrentRangeException()
            val length = suffixLength.coerceAtMost(totalLength)
            return DirectTorrentByteRange(totalLength - length, totalLength - 1L)
        }

        val start = first.toLongOrNull() ?: throw DirectTorrentRangeException()
        if (start < 0L || start >= totalLength) throw DirectTorrentRangeException()
        val requestedEnd = if (last.isEmpty()) {
            totalLength - 1L
        } else {
            last.toLongOrNull() ?: throw DirectTorrentRangeException()
        }
        if (requestedEnd < start) throw DirectTorrentRangeException()
        return DirectTorrentByteRange(start, requestedEnd.coerceAtMost(totalLength - 1L))
    }
}
