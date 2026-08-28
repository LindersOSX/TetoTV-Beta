package dev.animetv.anime_tv

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.content.res.Configuration
import android.os.Build
import androidx.annotation.RequiresApi
import org.json.JSONArray
import org.json.JSONObject
import java.io.PrintWriter
import java.io.StringWriter
import java.net.Inet6Address
import java.net.InetAddress

/**
 * Keeps at most one consented upload until Flutter confirms delivery, plus a
 * bounded 48-hour redacted local summary ring for a later explicit diagnostic
 * share. No stable installation or device identifier is created or stored.
 */
object AnonymousCrashStore {
    private const val PREFS_NAME = "anonymous_crash_reporting"
    private const val ENABLED_KEY = "enabled"
    private const val QUEUED_REPORT_KEY = "queued_report"
    private const val LAST_EXIT_TIMESTAMP_KEY = "last_exit_timestamp"
    private const val LOCAL_CRASH_SUMMARIES_KEY = "local_crash_summaries"
    private const val LOCAL_DROPPED_AGE_KEY = "local_crash_dropped_age"
    private const val LOCAL_DROPPED_CAPACITY_KEY = "local_crash_dropped_capacity"
    private const val LOCAL_LAST_SCANNED_EXIT_KEY = "local_crash_last_scanned_exit"
    private const val MAX_QUEUED_BYTES = 12_000
    private const val MAX_TRACE_CHARS = 4_000
    private const val MAX_LOCAL_TRACE_CHARS = 1_800
    private const val MAX_LOCAL_CRASH_SUMMARIES = 12
    private const val LOCAL_HISTORY_MILLIS = 48L * 60L * 60L * 1_000L

    fun setEnabled(context: Context, enabled: Boolean) {
        val preferences = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val wasEnabled = preferences.getBoolean(ENABLED_KEY, false)
        preferences.edit().apply {
            putBoolean(ENABLED_KEY, enabled)
            if (!enabled) remove(QUEUED_REPORT_KEY)
            // A report created before explicit consent must never be uploaded
            // if the user enables reporting later.
            if (!enabled || !wasEnabled) {
                putLong(LAST_EXIT_TIMESTAMP_KEY, System.currentTimeMillis())
            }
        }.apply()
    }

    fun store(context: Context, report: Map<*, *>): Boolean {
        return storeReport(context, report, immediate = false)
    }

    private fun storeReport(
        context: Context,
        report: Map<*, *>,
        immediate: Boolean,
    ): Boolean {
        val preferences = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        if (!preferences.getBoolean(ENABLED_KEY, false)) return false
        val json = runCatching { JSONObject(report).toString() }.getOrNull() ?: return false
        if (json.toByteArray(Charsets.UTF_8).size > MAX_QUEUED_BYTES) return false
        val edit = preferences.edit().putString(QUEUED_REPORT_KEY, json)
        // An uncaught exception normally terminates the process immediately
        // after this handler returns, so that one write must reach disk now.
        return if (immediate) edit.commit() else {
            edit.apply()
            true
        }
    }

    fun storeUnhandledJavaCrash(context: Context, thread: Thread, error: Throwable) {
        val writer = StringWriter()
        runCatching { error.printStackTrace(PrintWriter(writer)) }
        val now = System.currentTimeMillis()
        val isTelevision =
            context.resources.configuration.uiMode and Configuration.UI_MODE_TYPE_MASK ==
                Configuration.UI_MODE_TYPE_TELEVISION
        val report = linkedMapOf<String, Any?>(
                "report_id" to "java-$now-${thread.id}",
                "kind" to "java",
                "message" to sanitize(
                    "${error.javaClass.simpleName}: ${error.message.orEmpty()}",
                    500,
                ),
                "stack" to sanitizeStack(writer.toString(), MAX_TRACE_CHARS),
                "occurred_at_ms" to now,
                "android_sdk" to Build.VERSION.SDK_INT,
                "abi" to (Build.SUPPORTED_ABIS.firstOrNull() ?: "unknown"),
                "device_class" to if (isTelevision) "tv" else "phone",
        )
        // Keep a small redacted local summary whether or not anonymous upload
        // consent is enabled. It can only leave the device after the user
        // explicitly shares a diagnostic report.
        storeLocalCrashSummary(context, report, immediate = true)
        storeReport(context, report, immediate = true)
    }

    fun recentLocalCrashSummaries(context: Context): Map<String, Any?> {
        val now = System.currentTimeMillis()
        val preferences = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val summaries = decodeSummaryArray(
            preferences.getString(LOCAL_CRASH_SUMMARIES_KEY, null),
        ).toMutableList()
        var newestScannedExit = preferences.getLong(LOCAL_LAST_SCANNED_EXIT_KEY, 0L)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val previouslyScannedExit = newestScannedExit
            val activityManager =
                context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            activityManager
                // Android documents zero as "all available". The result is
                // still OS-bounded, and the local report ring below remains 12.
                .getHistoricalProcessExitReasons(context.packageName, 0, 0)
                .asSequence()
                .filter {
                    it.timestamp > previouslyScannedExit && isReportableReason(it.reason)
                }
                .mapNotNull { exit -> exitSummary(context, exit) }
                .forEach { summary ->
                    summaries.add(summary)
                    newestScannedExit = maxOf(
                        newestScannedExit,
                        (summary["occurred_at_ms"] as? Number)?.toLong() ?: 0L,
                    )
                }
        }
        val bounded = boundLocalCrashSummaryHistory(summaries, now)
        val droppedOutsideWindow = preferences.getLong(LOCAL_DROPPED_AGE_KEY, 0L) +
            bounded.droppedOutsideWindow
        val droppedForCapacity = preferences.getLong(LOCAL_DROPPED_CAPACITY_KEY, 0L) +
            bounded.droppedForCapacity
        persistLocalCrashSummaries(
            context,
            bounded.summaries,
            immediate = false,
            droppedOutsideWindow = droppedOutsideWindow,
            droppedForCapacity = droppedForCapacity,
            newestScannedExit = newestScannedExit,
        )
        return linkedMapOf(
            "summaries" to bounded.summaries,
            "dropped_outside_window" to droppedOutsideWindow,
            "dropped_for_capacity" to droppedForCapacity,
        )
    }

    fun pending(context: Context): Map<String, Any?>? {
        val preferences = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        if (!preferences.getBoolean(ENABLED_KEY, false)) return null
        preferences.getString(QUEUED_REPORT_KEY, null)?.let { encoded ->
            decode(encoded)?.let { return it }
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null

        val lastTimestamp = preferences.getLong(LAST_EXIT_TIMESTAMP_KEY, 0L)
        val activityManager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val exit = activityManager
            .getHistoricalProcessExitReasons(context.packageName, 0, 10)
            .asSequence()
            .filter { it.timestamp > lastTimestamp && isReportableReason(it.reason) }
            .minByOrNull { it.timestamp }
            ?: return null
        val reportId = "android-exit-${exit.timestamp}-${exit.reason}"
        val kind = when (exit.reason) {
            ApplicationExitInfo.REASON_ANR -> "anr"
            ApplicationExitInfo.REASON_CRASH_NATIVE -> "native"
            else -> "java"
        }
        val message = when (exit.reason) {
            ApplicationExitInfo.REASON_ANR -> "Android reported that TetoTV stopped responding."
            ApplicationExitInfo.REASON_CRASH_NATIVE -> "Android reported a native TetoTV process crash."
            else -> "Android reported an unhandled TetoTV process crash."
        }
        val trace = runCatching {
            exit.traceInputStream?.bufferedReader()?.use { reader ->
                val buffer = CharArray(MAX_TRACE_CHARS)
                val count = reader.read(buffer)
                if (count > 0) String(buffer, 0, count) else ""
            }
        }.getOrNull().orEmpty()
        val details = listOfNotNull(
            sanitize(exit.description.orEmpty(), 700).takeIf { it.isNotEmpty() },
            sanitizeStack(trace, MAX_TRACE_CHARS).takeIf { it.isNotEmpty() },
        ).joinToString(" | ")
        val isTelevision =
            context.resources.configuration.uiMode and Configuration.UI_MODE_TYPE_MASK ==
                Configuration.UI_MODE_TYPE_TELEVISION
        return linkedMapOf(
            "report_id" to reportId,
            "kind" to kind,
            "message" to message,
            "stack" to details,
            "occurred_at_ms" to exit.timestamp,
            "android_sdk" to Build.VERSION.SDK_INT,
            "abi" to (Build.SUPPORTED_ABIS.firstOrNull() ?: "unknown"),
            "device_class" to if (isTelevision) "tv" else "phone",
        )
    }

    fun acknowledge(context: Context, reportId: String) {
        val preferences = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val queued = preferences.getString(QUEUED_REPORT_KEY, null)
        if (queued != null && decode(queued)?.get("report_id") == reportId) {
            preferences.edit()
                .remove(QUEUED_REPORT_KEY)
                .putLong(LAST_EXIT_TIMESTAMP_KEY, System.currentTimeMillis())
                .apply()
            return
        }
        val match = Regex("^android-exit-(\\d+)-\\d+$").matchEntire(reportId) ?: return
        val timestamp = match.groupValues[1].toLongOrNull() ?: return
        val current = preferences.getLong(LAST_EXIT_TIMESTAMP_KEY, 0L)
        if (timestamp > current) {
            preferences.edit().putLong(LAST_EXIT_TIMESTAMP_KEY, timestamp).apply()
        }
    }

    fun clear(context: Context) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .remove(QUEUED_REPORT_KEY)
            .putLong(LAST_EXIT_TIMESTAMP_KEY, System.currentTimeMillis())
            .apply()
    }

    @RequiresApi(Build.VERSION_CODES.R)
    private fun exitSummary(context: Context, exit: ApplicationExitInfo): Map<String, Any?>? {
        if (exit.timestamp <= 0L) return null
        val kind = when (exit.reason) {
            ApplicationExitInfo.REASON_ANR -> "anr"
            ApplicationExitInfo.REASON_CRASH_NATIVE -> "native"
            else -> "java"
        }
        val message = when (exit.reason) {
            ApplicationExitInfo.REASON_ANR -> "Android reported that TetoTV stopped responding."
            ApplicationExitInfo.REASON_CRASH_NATIVE -> "Android reported a native TetoTV process crash."
            else -> "Android reported an unhandled TetoTV process crash."
        }
        val trace = runCatching {
            exit.traceInputStream?.bufferedReader()?.use { reader ->
                val buffer = CharArray(MAX_LOCAL_TRACE_CHARS)
                val count = reader.read(buffer)
                if (count > 0) String(buffer, 0, count) else ""
            }
        }.getOrNull().orEmpty()
        val details = listOfNotNull(
            sanitize(exit.description.orEmpty(), 500).takeIf { it.isNotEmpty() },
            sanitizeStack(trace, MAX_LOCAL_TRACE_CHARS).takeIf { it.isNotEmpty() },
        ).joinToString(" | ")
        val isTelevision =
            context.resources.configuration.uiMode and Configuration.UI_MODE_TYPE_MASK ==
                Configuration.UI_MODE_TYPE_TELEVISION
        return linkedMapOf(
            "report_id" to "android-exit-${exit.timestamp}-${exit.reason}",
            "kind" to kind,
            "message" to message,
            "stack" to details,
            "occurred_at_ms" to exit.timestamp,
            "android_sdk" to Build.VERSION.SDK_INT,
            "abi" to (Build.SUPPORTED_ABIS.firstOrNull() ?: "unknown"),
            "device_class" to if (isTelevision) "tv" else "phone",
        )
    }

    private fun storeLocalCrashSummary(
        context: Context,
        report: Map<String, Any?>,
        immediate: Boolean,
    ) {
        val preferences = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val existing = decodeSummaryArray(preferences.getString(LOCAL_CRASH_SUMMARIES_KEY, null))
        val bounded = boundLocalCrashSummaryHistory(
            existing + sanitizeLocalCrashSummary(report),
            System.currentTimeMillis(),
        )
        persistLocalCrashSummaries(
            context,
            bounded.summaries,
            immediate,
            droppedOutsideWindow = preferences.getLong(LOCAL_DROPPED_AGE_KEY, 0L) +
                bounded.droppedOutsideWindow,
            droppedForCapacity = preferences.getLong(LOCAL_DROPPED_CAPACITY_KEY, 0L) +
                bounded.droppedForCapacity,
            newestScannedExit = preferences.getLong(LOCAL_LAST_SCANNED_EXIT_KEY, 0L),
        )
    }

    private fun persistLocalCrashSummaries(
        context: Context,
        summaries: List<Map<String, Any?>>,
        immediate: Boolean,
        droppedOutsideWindow: Long,
        droppedForCapacity: Long,
        newestScannedExit: Long,
    ) {
        val array = JSONArray()
        summaries.forEach { array.put(JSONObject(it)) }
        val encoded = array.toString()
        val edit = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(LOCAL_CRASH_SUMMARIES_KEY, encoded)
            .putLong(LOCAL_DROPPED_AGE_KEY, droppedOutsideWindow.coerceAtLeast(0L))
            .putLong(LOCAL_DROPPED_CAPACITY_KEY, droppedForCapacity.coerceAtLeast(0L))
            .putLong(LOCAL_LAST_SCANNED_EXIT_KEY, newestScannedExit.coerceAtLeast(0L))
        if (immediate) edit.commit() else edit.apply()
    }

    private fun decodeSummaryArray(value: String?): List<Map<String, Any?>> {
        if (value.isNullOrBlank()) return emptyList()
        return runCatching {
            val array = JSONArray(value)
            buildList {
                for (index in 0 until array.length()) {
                    val item = array.optJSONObject(index) ?: continue
                    add(buildMap {
                        for (key in item.keys()) {
                            put(key, item.opt(key).takeUnless { it === JSONObject.NULL })
                        }
                    })
                }
            }
        }.getOrDefault(emptyList())
    }

    internal data class LocalCrashSummaryWindow(
        val summaries: List<Map<String, Any?>>,
        val droppedOutsideWindow: Int,
        val droppedForCapacity: Int,
    )

    internal fun boundLocalCrashSummaryHistory(
        summaries: List<Map<String, Any?>>,
        nowMillis: Long,
    ): LocalCrashSummaryWindow {
        val cutoff = nowMillis - LOCAL_HISTORY_MILLIS
        val distinct = summaries
            .asSequence()
            .map(::sanitizeLocalCrashSummary)
            .distinctBy {
                val timestamp = (it["occurred_at_ms"] as? Number)?.toLong() ?: 0L
                "${it["kind"]}:${timestamp / 1_000L}"
            }
            .sortedBy { (it["occurred_at_ms"] as? Number)?.toLong() ?: 0L }
            .toList()
        val retained = distinct.filter {
            val timestamp = (it["occurred_at_ms"] as? Number)?.toLong() ?: 0L
            timestamp in cutoff..nowMillis
        }
        val droppedForCapacity = (retained.size - MAX_LOCAL_CRASH_SUMMARIES).coerceAtLeast(0)
        return LocalCrashSummaryWindow(
            summaries = retained.takeLast(MAX_LOCAL_CRASH_SUMMARIES),
            droppedOutsideWindow = distinct.size - retained.size,
            droppedForCapacity = droppedForCapacity,
        )
    }

    internal fun boundLocalCrashSummaries(
        summaries: List<Map<String, Any?>>,
        nowMillis: Long,
    ): List<Map<String, Any?>> = boundLocalCrashSummaryHistory(summaries, nowMillis).summaries

    private fun sanitizeLocalCrashSummary(value: Map<String, Any?>): Map<String, Any?> =
        linkedMapOf(
            "kind" to when (value["kind"]?.toString()) {
                "java", "native", "anr", "flutter", "platform" -> value["kind"].toString()
                else -> "native"
            },
            "message" to sanitize(value["message"]?.toString().orEmpty(), 500),
            "stack" to sanitizeStack(value["stack"]?.toString().orEmpty(), MAX_LOCAL_TRACE_CHARS),
            "occurred_at_ms" to ((value["occurred_at_ms"] as? Number)?.toLong() ?: 0L),
        )

    internal fun isReportableReason(reason: Int): Boolean =
        reason == ApplicationExitInfo.REASON_CRASH ||
            reason == ApplicationExitInfo.REASON_CRASH_NATIVE ||
            reason == ApplicationExitInfo.REASON_ANR

    private fun decode(value: String): Map<String, Any?>? = runCatching {
        val objectValue = JSONObject(value)
        buildMap {
            for (key in objectValue.keys()) {
                put(key, objectValue.opt(key).takeUnless { it === JSONObject.NULL })
            }
        }
    }.getOrNull()

    internal fun sanitize(value: String, maximum: Int): String {
        var output = value
            .replace(Regex("https?://[^\\s\\\"']+", RegexOption.IGNORE_CASE), "[URL]")
            .replace(
                // JSON-encoded exception text can escape each slash while
                // leaving the URL otherwise intact.
                Regex("https?:\\\\/\\\\/[^\\s\\\"']+", RegexOption.IGNORE_CASE),
                "[URL]",
            )
            .replace(
                Regex("(?<![A-Za-z0-9:])//[^\\s\\\"']+", RegexOption.IGNORE_CASE),
                "[URL]",
            )
            .replace(
                // Requiring a path and alphabetic DNS suffix keeps dotted
                // versions, shared-library names, and class names useful.
                Regex(
                    "\\b(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,62})\\.)+[A-Za-z]{2,63}(?::\\d{1,5})?/(?!/)[^\\s\\\"']*",
                    RegexOption.IGNORE_CASE,
                ),
                "[URL]",
            )
            .replace(
                Regex(
                    "\\b(?:[A-Za-z0-9-]+\\.)+[A-Za-z]{2,}(?::\\d{1,5})?(?:/[^\\s\\\"']*)?[?&](?:x-amz-signature|x-amz-credential|x-amz-security-token|signature|sig|token)=[^\\s\\\"']+",
                    RegexOption.IGNORE_CASE,
                ),
                "[URL]",
            )
            .replace(Regex("magnet:\\?[^\\s\\\"']+", RegexOption.IGNORE_CASE), "[MAGNET]")
            .replace(
                Regex(
                    "\\b(?![A-Za-z]:[\\\\/])[A-Za-z][A-Za-z0-9+.-]{0,31}:(?![0-9\\s])[^\\s\\\"'<>]+",
                    RegexOption.IGNORE_CASE,
                ),
                "[URI]",
            )
            .replace(
                Regex(
                    "(^|[\\s\\\"'(=\\[])(?:[A-Za-z]:[\\\\/]|\\\\\\\\[^\\\\/\\s\\\"'<>]+[\\\\/])[^\\r\\n\\\"'<>]*",
                )
            ) { match -> "${match.groupValues[1]}[PATH]" }
            .replace(Regex("(^|[\\s\\\"'(=\\[])/(?!/)[^\\r\\n\\\"'<>]*")) { match ->
                "${match.groupValues[1]}[PATH]"
            }
            .replace(Regex("\\bgithub_pat_[A-Za-z0-9_]+\\b", RegexOption.IGNORE_CASE), "[REDACTED]")
            .replace(Regex("\\bgh[pousr]_[A-Za-z0-9]{20,}\\b", RegexOption.IGNORE_CASE), "[REDACTED]")
            .replace(Regex("\\beyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\b"), "[REDACTED]")
            .replace(Regex("bearer\\s+[^\\s,;\\\"']+", RegexOption.IGNORE_CASE), "Bearer [REDACTED]")
            .replace(Regex("basic\\s+[^\\s,;\\\"']+", RegexOption.IGNORE_CASE), "Basic [REDACTED]")
            .replace(
                Regex(
                    "(?<![A-Za-z0-9_-])[\\\"']?(?:set-cookie|cookie)[\\\"']?\\s*[:=]\\s*[\\\"']?[^\\r\\n]+",
                    RegexOption.IGNORE_CASE,
                ),
                "[REDACTED]",
            )
            .replace(
                Regex(
                    "(?<![A-Za-z0-9_-])[\\\"']?(?:authorization|access[_ -]?token|refresh[_ -]?token|token|api[_ -]?key|client[_ -]?secret|password|x-amz-signature|x-amz-credential|x-amz-security-token|signature|sig)[\\\"']?\\s*[:=]\\s*[\\\"']?[^\\s,;&\\\"']+",
                    RegexOption.IGNORE_CASE,
                ),
                "[REDACTED]",
            )
            .replace(
                Regex(
                    "(?<![A-Za-z0-9_])[\\\"']?(?:room[_ -]?code|capability|tracker[_ -]?id|anilist[_ -]?(?:id|media[_ -]?id)|mal[_ -]?(?:id|media[_ -]?id)|account[_ -]?id|user[_ -]?id|user[_ -]?name|display[_ -]?name|avatar|(?:raw[_ -]?)?source(?:[_ -]?id)?|(?:raw[_ -]?)?stream(?:[_ -]?id)?|torrent[_ -]?hash|info[_ -]?hash)[\\\"']?\\s*[:=]\\s*[\\\"']?[^\\s,;\\\"']+",
                    RegexOption.IGNORE_CASE,
                ),
                "[PRIVATE CONTEXT REDACTED]",
            )
            .replace(Regex("(?<![0-9])[2-9]{8}(?![0-9])"), "[ROOM CODE]")
            .replace(Regex("\\b[a-fA-F0-9]{32,}\\b"), "[REDACTED]")
            .replace(Regex("\\b[A-Z2-7]{32,52}\\b", RegexOption.IGNORE_CASE), "[REDACTED]")
            .replace(
                Regex("\\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}\\b", RegexOption.IGNORE_CASE),
                "[EMAIL]",
            )
        output = redactNetworkAddresses(output)
            .replace(Regex("[\\r\\n]+"), " ")
            .trim()
        if (output.length > maximum) output = output.substring(0, maximum)
        return output
    }

    internal fun sanitizeStack(value: String, maximum: Int): String {
        val output = value
            .lineSequence()
            .take(50)
            .map { sanitize(it, 300) }
            .filter { it.isNotEmpty() }
            .joinToString("\n")
        return if (output.length <= maximum) output else output.substring(0, maximum)
    }

    private fun redactNetworkAddresses(value: String): String {
        var output = value
            .replace(
                Regex(
                    "(?<![A-Za-z0-9])\\[?::ffff:(?:\\d{1,3}\\.){3}\\d{1,3}\\]?(?![A-Za-z0-9])",
                    RegexOption.IGNORE_CASE,
                ),
                "[NETWORK ADDRESS]",
            )
            .replace(
                Regex("\\b(?:[0-9A-F]{2}[:-]){5}[0-9A-F]{2}\\b", RegexOption.IGNORE_CASE),
                "[NETWORK ADDRESS]",
            )
            .replace(
                Regex("(?<![A-Za-z0-9])(?:\\d{1,3}\\.){3}\\d{1,3}(?![A-Za-z0-9])"),
                "[NETWORK ADDRESS]",
            )
        output = output.replace(
            Regex(
                "(?<![A-Za-z0-9])\\[?[0-9A-Fa-f:.]*:[0-9A-Fa-f:.]+(?:%[A-Za-z0-9_.-]+)?\\]?(?![A-Za-z0-9])",
            ),
        ) { match ->
            val original = match.value
            var candidate = original.trim('[', ']')
            var trailingDots = ""
            while (candidate.endsWith('.')) {
                candidate = candidate.dropLast(1)
                trailingDots += "."
            }
            val addressCandidate = candidate.substringBeforeLast('%', candidate)
            val address = runCatching { InetAddress.getByName(addressCandidate) }.getOrNull()
            if (address is Inet6Address) "[NETWORK ADDRESS]$trailingDots" else original
        }
        return output
    }
}
