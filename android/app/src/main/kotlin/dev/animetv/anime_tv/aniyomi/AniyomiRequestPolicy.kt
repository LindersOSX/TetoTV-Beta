package dev.animetv.anime_tv.aniyomi

import dev.animetv.anime_tv.aniyomi.compat.AniyomiCompatRuntime
import org.json.JSONObject

/**
 * Strictly validates the Flutter-to-host Aniyomi request envelope.
 *
 * [timeoutMs] belongs to the trusted scheduling boundary. It is accepted and
 * bounded here, but intentionally omitted from the values handed to
 * third-party extension methods. Videos receive only a derived, upper-bounded
 * hoster scheduling window used by our trusted runtime orchestration. This
 * keeps the Dart and Android request contracts aligned without allowing an
 * extension to weaken either process deadline.
 */
internal object AniyomiRequestPolicy {
    fun sanitize(arguments: Map<*, *>): JSONObject {
        val envelope = extensionEnvelope(arguments)
        val json = JSONObject()
        envelope.forEach(json::put)
        AniyomiPolicy.boundedText(json.toString(), AniyomiPolicy.MAX_REQUEST_BYTES)
        return json
    }

    /** Pure-JVM view of exactly what may be copied into the worker request. */
    internal fun extensionEnvelope(arguments: Map<*, *>): Map<String, Any> {
        val allowed = setOf(
            "extensionId",
            "operation",
            "sourceId",
            "query",
            "page",
            "url",
            "title",
            "timeoutMs",
            "requestId",
            "targetEpisode",
            "targetSeason",
            "resolveLazyHosters",
            "lazyHosterLimit",
        )
        require(arguments.keys.all { it in allowed })
        require((arguments["extensionId"] as? String)?.let {
            it.length <= 240 && it.startsWith("aniyomi:")
        } == true)
        val operation = arguments["operation"] as? String
        require(operation in AniyomiPolicy.operations)

        val operationBudgetMs = arguments["timeoutMs"]?.let { raw ->
            require(raw is Number)
            val milliseconds = raw.toLong()
            require(
                raw.toDouble().isFinite() &&
                    raw.toDouble() == milliseconds.toDouble() &&
                    milliseconds in 1..AniyomiPolicy.MAX_OPERATION_BUDGET_MS,
            )
            milliseconds
        }
        clientRequestId(arguments)

        val envelope = linkedMapOf<String, Any>("operation" to operation!!)
        for (key in listOf("sourceId", "query", "url", "title")) {
            arguments[key]?.let {
                require(it is String)
                val maximum = when (key) {
                    "sourceId" -> 24
                    "url" -> 4096
                    else -> 512
                }
                envelope[key] = AniyomiPolicy.boundedText(it, maximum)
            }
        }
        if (operation != "sources") {
            require((envelope["sourceId"] as? String)?.matches(Regex("-?[0-9]{1,20}")) == true)
        }
        arguments["targetEpisode"]?.let { raw ->
            require(operation == "episodes" && raw is Number)
            val value = raw.toLong()
            require(
                raw.toDouble().isFinite() && raw.toDouble() == value.toDouble() && value in 1..100_000,
            )
            envelope["targetEpisode"] = value.toInt()
        }
        arguments["targetSeason"]?.let { raw ->
            require(
                (operation == "episodes" && arguments.containsKey("targetEpisode") || operation == "seasons") &&
                    raw is Number,
            )
            val value = raw.toLong()
            require(raw.toDouble().isFinite() && raw.toDouble() == value.toDouble() && value in 0..1000)
            envelope["targetSeason"] = value.toInt()
        }
        arguments["resolveLazyHosters"]?.let { raw ->
            require(operation == "videos" && raw is Boolean)
            envelope["resolveLazyHosters"] = raw
        }
        arguments["lazyHosterLimit"]?.let { raw ->
            require(
                operation == "videos" &&
                    arguments["resolveLazyHosters"] == true &&
                    raw is Number,
            )
            val value = raw.toLong()
            require(
                raw.toDouble().isFinite() &&
                    raw.toDouble() == value.toDouble() &&
                    value in 1..AniyomiCompatRuntime.MAX_LAZY_HOSTERS_PER_REQUEST,
            )
            envelope["lazyHosterLimit"] = value.toInt()
        }
        if (operation == "videos") {
            val budget = operationBudgetMs ?: AniyomiPolicy.MAX_OPERATION_BUDGET_MS
            envelope["hosterWorkBudgetMs"] = minOf(
                (budget - minOf(1_500L, budget / 5)).coerceAtLeast(1L),
                AniyomiCompatRuntime.MAX_HOSTER_WORK_MS,
            )
            envelope["hosterLoadTimeoutMs"] = minOf(
                operationBudgetMs ?: AniyomiCompatRuntime.MAX_HOSTER_LOAD_MS,
                AniyomiCompatRuntime.MAX_HOSTER_LOAD_MS,
            )
        }
        if (operation == "seasons") require(envelope.containsKey("targetSeason"))
        val page = arguments["page"] ?: 1
        require(
            page is Number &&
                page.toDouble().isFinite() &&
                page.toLong() in 1..100 &&
                page.toDouble() == page.toLong().toDouble(),
        )
        envelope["page"] = page.toInt()
        return envelope
    }

    /** Trusted cancellation correlation metadata; never copied into provider JSON. */
    internal fun clientRequestId(arguments: Map<*, *>): Long? {
        val raw = arguments["requestId"] ?: return null
        require(raw is Number)
        val value = raw.toLong()
        require(
            raw.toDouble().isFinite() &&
                raw.toDouble() == value.toDouble() &&
                value in 1..Int.MAX_VALUE.toLong(),
        )
        return value
    }
}
