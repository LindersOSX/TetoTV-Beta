package dev.animetv.anime_tv.aniyomi

import dev.animetv.anime_tv.aniyomi.compat.AniyomiCompatRuntime

/** Host-side whitelist: a compromised worker cannot return player arguments, intents or file capabilities. */
internal object AniyomiResultPolicy {
    fun sanitize(
        operation: String,
        input: Map<*, *>,
        privateMangaImages: Boolean = false,
    ): Map<String, Any?> =
        sanitizeOperation(operation, input, privateMangaImages) + brokerContext(input)

    private fun sanitizeOperation(
        operation: String,
        input: Map<*, *>,
        privateMangaImages: Boolean,
    ): Map<String, Any?> = when (operation) {
        "sources" -> mapOf("sources" to rows(input["sources"], 32).map {
            val id = text(it["id"], 24)
            require(id.toLongOrNull() != null)
            val kind = text(it["kind"], 8)
            require(kind == "anime" || kind == "manga")
            mapOf("id" to id, "name" to text(it["name"], 160), "lang" to text(it["lang"], 24),
                "kind" to kind, "baseUrl" to optionalPublicUrl(it["baseUrl"]),
                "supportsLatest" to (it["supportsLatest"] == true))
        })
        "search" -> rows(input["items"], 100).let { itemRows ->
            mapOf("items" to itemRows.map { item(it, privateMangaImages) }, "hasNextPage" to (input["hasNextPage"] == true)) +
                optionalListCounts(input, itemRows.size, maximumOriginal = 10_000)
        }
        "details" -> mapOf("item" to item(
            input["item"] as? Map<*, *> ?: error("invalid_item"),
            privateMangaImages,
        ))
        "seasons" -> rows(input["seasons"], 16).let { seasonRows ->
            val original = count(input["originalCount"], 1_000)
            val returned = count(input["returnedCount"], 16)
            val filtered = count(input["filteredCount"], 1_000)
            val truncated = count(input["truncatedCount"], 1_000)
            require(returned == seasonRows.size && original == returned + filtered + truncated)
            mapOf(
                "seasons" to seasonRows.map { item(it, privateMangaImages = false) },
                "originalCount" to original,
                "returnedCount" to returned,
                "filteredCount" to filtered,
                "truncatedCount" to truncated,
            )
        }
        "chapters", "episodes" -> rows(input["chapters"], 2000).let { chapterRows -> mapOf("chapters" to chapterRows.map {
            val number = (it["number"] as? Number)?.toDouble() ?: -1.0
            require(number.isFinite())
            mapOf("url" to text(it["url"], 4096), "name" to text(it["name"], 512), "number" to number,
                "dateUpload" to ((it["dateUpload"] as? Number)?.toLong() ?: 0L), "scanlator" to optionalText(it["scanlator"], 256))
        }).let { result ->
            if (operation != "episodes") {
                result + optionalListCounts(input, chapterRows.size, maximumOriginal = 2000)
            } else {
                val original = count(input["originalCount"], 100_000)
                val returned = count(input["returnedCount"], 2000)
                val filtered = count(input["filteredCount"], 100_000)
                val truncated = count(input["truncatedCount"], 100_000)
                require(returned == chapterRows.size && original == returned + filtered + truncated)
                result + mapOf(
                    "originalCount" to original,
                    "returnedCount" to returned,
                    "filteredCount" to filtered,
                    "truncatedCount" to truncated,
                )
            }
        } }
        "pages" -> rows(input["pages"], 1000).let { pageRows ->
            mapOf("pages" to pageRows.mapIndexed { index, row ->
                // Preserve provider list order while replacing untrusted sparse
                // or duplicate indexes with a stable contiguous sequence.
                mapOf(
                    "index" to index,
                    "url" to publicUrl(row["url"]),
                    "headers" to if (privateMangaImages) imageHeaders(row["headers"]) else headers(row["headers"]),
                )
            }) + optionalListCounts(input, pageRows.size, maximumOriginal = 1000)
        }
        "videos" -> rows(input["videos"], 32).let { videoRows ->
            val discarded = optionalCount(
                input["discardedVideoCount"],
                AniyomiCompatRuntime.MAX_AGGREGATE_VIDEOS,
            ) ?: 0
            val truncated = optionalCount(
                input["truncatedCount"],
                AniyomiCompatRuntime.MAX_AGGREGATE_VIDEOS,
            ) ?: 0
            val original = optionalCount(
                input["originalCount"],
                AniyomiCompatRuntime.MAX_AGGREGATE_VIDEOS,
            )
            val returned = optionalCount(input["returnedCount"], 32)
            require(returned == null || returned == videoRows.size)
            require(original == null || original == videoRows.size + discarded + truncated)
            val originalHosters = optionalCount(input["originalHosterCount"], 1024)
            val visitedHosters = optionalCount(input["visitedHosterCount"], 64)
            val truncatedHosters = optionalCount(input["truncatedHosterCount"], 1024)
            val lazyHosters = optionalCount(input["lazyHosterCount"], 1024)
            val attemptedLazy = optionalCount(
                input["attemptedLazyHosterCount"],
                AniyomiCompatRuntime.MAX_LAZY_HOSTERS_PER_REQUEST,
            )
            val resolvedLazy = optionalCount(
                input["resolvedLazyHosterCount"],
                AniyomiCompatRuntime.MAX_LAZY_HOSTERS_PER_REQUEST,
            )
            val failedLazy = optionalCount(
                input["failedLazyHosterCount"],
                AniyomiCompatRuntime.MAX_LAZY_HOSTERS_PER_REQUEST,
            )
            require(
                originalHosters == null ||
                    visitedHosters != null && truncatedHosters != null &&
                    originalHosters == visitedHosters + truncatedHosters,
            )
            require(lazyHosters == null || originalHosters != null && lazyHosters <= originalHosters)
            require(
                attemptedLazy == null ||
                    resolvedLazy != null && failedLazy != null &&
                    attemptedLazy == resolvedLazy + failedLazy,
            )
            require(attemptedLazy == null || lazyHosters != null && attemptedLazy <= lazyHosters)
            mapOf("videos" to videoRows.map {
                mapOf("url" to publicUrl(it["url"]), "quality" to text(it["quality"], 160),
                    "headers" to headers(it["headers"]), "subtitleTracks" to tracks(it["subtitleTracks"]),
                    "audioTracks" to tracks(it["audioTracks"]))
            }, "discardedVideoCount" to discarded, "truncatedCount" to truncated) +
                (original?.let { mapOf("originalCount" to it, "returnedCount" to returned!!) } ?: emptyMap()) +
                optionalSingleCount(input, "truncatedHosterCount", 1024) +
                optionalSingleCount(input, "discardedHosterCount", 1024) +
                optionalSingleCount(input, "deferredHosterCount", 1024) +
                optionalSingleCount(input, "originalHosterCount", 1024) +
                optionalSingleCount(input, "visitedHosterCount", 64) +
                optionalSingleCount(input, "lazyHosterCount", 1024) +
                optionalSingleCount(
                    input,
                    "attemptedLazyHosterCount",
                    AniyomiCompatRuntime.MAX_LAZY_HOSTERS_PER_REQUEST,
                ) +
                optionalSingleCount(
                    input,
                    "resolvedLazyHosterCount",
                    AniyomiCompatRuntime.MAX_LAZY_HOSTERS_PER_REQUEST,
                ) +
                optionalSingleCount(
                    input,
                    "failedLazyHosterCount",
                    AniyomiCompatRuntime.MAX_LAZY_HOSTERS_PER_REQUEST,
                ) +
                optionalSingleCount(input, "discardedTrackCount", 1024) +
                optionalSingleCount(input, "localHlsBridgeCount", 32)
        }
        else -> throw IllegalArgumentException("unsupported_result_operation")
    }

    private fun optionalListCounts(input: Map<*, *>, actualReturned: Int, maximumOriginal: Int): Map<String, Int> {
        val original = optionalCount(input["originalCount"], maximumOriginal) ?: return emptyMap()
        val returned = count(input["returnedCount"], actualReturned)
        val truncated = count(input["truncatedCount"], maximumOriginal)
        require(returned == actualReturned && original == returned + truncated)
        return mapOf("originalCount" to original, "returnedCount" to returned, "truncatedCount" to truncated)
    }

    private fun optionalSingleCount(input: Map<*, *>, key: String, maximum: Int): Map<String, Int> =
        optionalCount(input[key], maximum)?.let { mapOf(key to it) } ?: emptyMap()

    private fun brokerContext(input: Map<*, *>): Map<String, Any?> {
        val redirect = input["broker_redirect_count"] ?: return emptyMap()
        val redirects = count(redirect, 3)
        val size = text(input["broker_response_size_bucket"], 16)
        val status = text(input["broker_status_class"], 4)
        require(size in setOf("none", "lt64k", "64to128k", "128to256k", "over256k"))
        require(status in setOf("none", "1xx", "2xx", "3xx", "4xx", "5xx"))
        return mapOf(
            "broker_redirect_count" to redirects,
            "broker_response_size_bucket" to size,
            "broker_status_class" to status,
        )
    }

    private fun item(
        input: Map<*, *>,
        privateMangaImages: Boolean,
    ): Map<String, Any?> = mutableMapOf<String, Any?>(
        // Source-relative paths remain opaque identifiers; they are never given directly to a player.
        "url" to text(input["url"], 4096), "title" to text(input["title"], 512),
        // Artwork is optional metadata. A provider may legitimately return a
        // cover on a non-standard HTTPS port or a malformed blank placeholder;
        // keep the catalog identity while dropping artwork that cannot pass
        // the host's strict public-HTTPS policy.
        "thumbnailUrl" to optionalArtworkUrl(input["thumbnailUrl"]),
        // Consumed and removed by the host's opaque image capability store.
        "thumbnailHeaders" to if (privateMangaImages) imageHeaders(input["thumbnailHeaders"]) else emptyMap<String, String>(),
        "description" to optionalText(input["description"], 16 * 1024), "author" to optionalText(input["author"], 512),
        "artist" to optionalText(input["artist"], 512), "genre" to optionalText(input["genre"], 1024),
        "status" to ((input["status"] as? Number)?.toInt() ?: 0),
    ).apply {
        input["fetchType"]?.let { raw ->
            val value = text(raw, 16)
            require(value == "episodes" || value == "seasons")
            put("fetchType", value)
        }
        input["seasonNumber"]?.let { raw ->
            val value = (raw as? Number)?.toDouble() ?: throw IllegalArgumentException("invalid_season_number")
            require(value.isFinite() && value in -1.0..1_000.0 && value == value.toInt().toDouble())
            put("seasonNumber", value)
        }
    }

    private fun tracks(value: Any?): List<Map<String, Any?>> = if (value == null) emptyList() else rows(value, 16).mapNotNull {
        try {
            mapOf("url" to publicUrl(it["url"]), "lang" to text(it["lang"], 64))
        } catch (_: Exception) {
            null
        }
    }

    private fun headers(value: Any?): Map<String, String> {
        if (value == null) return emptyMap()
        val map = value as? Map<*, *> ?: throw IllegalArgumentException("invalid_headers")
        require(map.size <= 8)
        return map.entries.associate { (rawKey, rawValue) ->
            val key = text(rawKey, 32)
            val lower = key.lowercase()
            require(lower in setOf(
                "user-agent", "referer", "origin", "accept", "accept-language", "range",
                "sec-fetch-dest", "sec-fetch-mode", "sec-fetch-site",
            ))
            val header = text(rawValue, 2048)
            require(header.none { it < ' ' || it == '\u007f' })
            if (lower == "referer" || lower == "origin") AniyomiPolicy.publicHttps(header)
            when (lower) {
                "sec-fetch-dest" -> require(header in setOf("audio", "empty", "video"))
                "sec-fetch-mode" -> require(header in setOf("cors", "navigate", "no-cors", "same-origin"))
                "sec-fetch-site" -> require(header in setOf("cross-site", "none", "same-origin", "same-site"))
            }
            key to header
        }
    }

    private fun imageHeaders(value: Any?): Map<String, String> {
        if (value == null) return emptyMap()
        val map = value as? Map<*, *> ?: throw IllegalArgumentException("invalid_headers")
        val strings = map.entries.associate { (rawKey, rawValue) ->
            (rawKey as? String ?: throw IllegalArgumentException("invalid_headers")) to
                (rawValue as? String ?: throw IllegalArgumentException("invalid_headers"))
        }
        return AniyomiImageHeaderPolicy.headers(strings)
    }

    private fun publicUrl(value: Any?): String = AniyomiPolicy.publicHttps(text(value, 4096)).toASCIIString()
    private fun optionalPublicUrl(value: Any?): String? = (value as? String)?.takeIf { it.isNotBlank() }?.let(::publicUrl)
    private fun optionalArtworkUrl(value: Any?): String? = try {
        optionalPublicUrl(value)
    } catch (_: IllegalArgumentException) {
        null
    } catch (_: IllegalStateException) {
        null
    }
    private fun optionalText(value: Any?, size: Int): String? = value?.let { text(it, size) }
    private fun count(value: Any?, maximum: Int): Int = (value as? Number)?.toInt()?.also {
        require(it in 0..maximum && value.toDouble() == it.toDouble())
    } ?: throw IllegalArgumentException("invalid_count")
    private fun optionalCount(value: Any?, maximum: Int): Int? = value?.let { count(it, maximum) }
    private fun text(value: Any?, size: Int): String = AniyomiPolicy.boundedText(value as? String ?: error("invalid_text"), size)
    private fun rows(value: Any?, maximum: Int): List<Map<*, *>> {
        val list = value as? List<*> ?: throw IllegalArgumentException("invalid_rows")
        require(list.size <= maximum)
        return list.map { it as? Map<*, *> ?: throw IllegalArgumentException("invalid_row") }
    }
}
