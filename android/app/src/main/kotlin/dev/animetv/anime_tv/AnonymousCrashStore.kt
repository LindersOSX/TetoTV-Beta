package dev.animetv.anime_tv

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.content.res.Configuration
import android.os.Build
import android.os.Debug
import android.os.Looper
import androidx.annotation.RequiresApi
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.PrintWriter
import java.io.StringWriter
import java.net.Inet6Address
import java.net.InetAddress
import java.security.MessageDigest
import java.util.zip.GZIPInputStream

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
    private const val BREADCRUMBS_KEY = "privacy_safe_crash_breadcrumbs"
    private const val MAX_QUEUED_BYTES = 12_000
    private const val MAX_TRACE_CHARS = 4_000
    private const val MAX_LOCAL_TRACE_CHARS = 1_800
    // The faulting thread may follow large memory maps and many other threads.
    // This is a local parsing bound, not an upload limit: raw tombstones never
    // leave the device, and the existing 1,800/4,000-character summaries remain.
    internal const val MAX_NATIVE_TRACE_BYTES = 1_048_576
    private const val MAX_NATIVE_PROTO_FIELDS = 65_536
    // Android ANR traces can place the main-thread stack after a long runtime
    // and GC preamble. Reading only 64 KB repeatedly captured that preamble
    // while dropping the thread that explained the freeze.
    private const val MAX_TEXT_TRACE_BYTES = 512_000
    private const val MAX_LOCAL_CRASH_SUMMARIES = 12
    private const val MAX_BREADCRUMBS = 16
    private const val MAX_PROCESS_STATE_BYTES = 120
    private const val LOCAL_HISTORY_MILLIS = 48L * 60L * 60L * 1_000L
    private const val BREADCRUMB_HISTORY_MILLIS = 10L * 60L * 1_000L

    @Volatile
    private var processBreadcrumbsInitialized = false

    /**
     * Records one fixed, privacy-safe lifecycle marker for crash correlation.
     *
     * Callers cannot attach values: only the allowlisted event codes below are
     * accepted. The bounded ring contains no media, provider, room, account,
     * file, URL, or credential data. Android's process-state summary receives
     * the same compact markers so they survive a native process death.
     */
    fun recordBreadcrumb(context: Context, eventCode: String) {
        if (eventCode !in BREADCRUMB_CODES) return
        val now = System.currentTimeMillis()
        synchronized(this) {
            val preferences = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val existing = if (processBreadcrumbsInitialized) {
                decodeBreadcrumbs(preferences.getString(BREADCRUMBS_KEY, null))
            } else {
                processBreadcrumbsInitialized = true
                emptyList()
            }
            val bounded = boundBreadcrumbs(
                existing + CrashBreadcrumb(eventCode, now),
                now,
            )
            preferences.edit()
                .putString(BREADCRUMBS_KEY, encodeBreadcrumbs(bounded))
                .apply()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val processSummary = encodeProcessStateSummary(bounded)
                runCatching {
                    val activityManager =
                        context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                    activityManager.setProcessStateSummary(processSummary)
                }
            }
        }
    }

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
                "stack" to composeCrashDetails(
                    contextLines = listOf(
                        currentProcessContext(),
                        currentBreadcrumbContext(context, now),
                        "java_context thread=${if (Looper.getMainLooper().thread === thread) "main" else "background"}",
                    ),
                    trace = sanitizeStack(writer.toString(), MAX_TRACE_CHARS),
                    maximum = MAX_TRACE_CHARS,
                ),
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
        val trace = exitTrace(exit, MAX_TRACE_CHARS)
        val details = exitDetails(context, exit, trace, MAX_TRACE_CHARS)
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
        val trace = exitTrace(exit, MAX_LOCAL_TRACE_CHARS)
        val details = exitDetails(context, exit, trace, MAX_LOCAL_TRACE_CHARS)
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

    /**
     * ApplicationExitInfo exposes ANR/Java traces as text, but Android exposes
     * native tombstones as protobuf bytes. Decoding those bytes with a text
     * reader produced the corrupted, unactionable stacks seen in crash reports.
     * Preserve only bounded, non-user-controlled crash tokens and a stable
     * signature; never upload the raw tombstone.
     */
    @RequiresApi(Build.VERSION_CODES.R)
    private fun exitTrace(exit: ApplicationExitInfo, maximumChars: Int): TraceEvidence {
        if (exit.reason == ApplicationExitInfo.REASON_CRASH_NATIVE) {
            return runCatching {
                exit.traceInputStream?.use { readNativeTrace(it, maximumChars) }
            }.getOrNull() ?: TraceEvidence("", "none", 0, false)
        }
        val maximumBytes = MAX_TEXT_TRACE_BYTES
        val bounded = runCatching {
            exit.traceInputStream?.use { stream ->
                readAtMost(stream, maximumBytes)
            }
        }.getOrNull() ?: BoundedBytes(ByteArray(0), truncated = false)
        if (bounded.bytes.isEmpty()) {
            return TraceEvidence("", "none", 0, bounded.truncated)
        }
        if (isGzip(bounded.bytes)) {
            val inflated = runCatching {
                GZIPInputStream(ByteArrayInputStream(bounded.bytes)).use { stream ->
                    readAtMost(stream, maximumBytes)
                }
            }.getOrNull()
            if (inflated != null) {
                return TraceEvidence(
                    safeTextTrace(inflated.bytes, maximumChars),
                    "gzip_text",
                    bounded.bytes.size,
                    bounded.truncated || inflated.truncated,
                )
            }
            return TraceEvidence(
                binaryTraceSignature(bounded.bytes),
                "gzip_unreadable",
                bounded.bytes.size,
                bounded.truncated,
            )
        }
        return if (looksLikeText(bounded.bytes)) {
            TraceEvidence(
                safeTextTrace(bounded.bytes, maximumChars),
                "text",
                bounded.bytes.size,
                bounded.truncated,
            )
        } else {
            TraceEvidence(
                binaryTraceSignature(bounded.bytes),
                "binary",
                bounded.bytes.size,
                bounded.truncated,
            )
        }
    }

    private fun readAtMost(stream: InputStream, maximumBytes: Int): BoundedBytes {
        val output = ByteArrayOutputStream(minOf(maximumBytes, 8_192))
        val buffer = ByteArray(4_096)
        while (output.size() < maximumBytes) {
            val count = stream.read(buffer, 0, minOf(buffer.size, maximumBytes - output.size()))
            if (count <= 0) break
            output.write(buffer, 0, count)
        }
        val truncated = output.size() >= maximumBytes && stream.read() >= 0
        return BoundedBytes(output.toByteArray(), truncated)
    }

    internal fun readNativeTrace(stream: InputStream, maximumChars: Int): TraceEvidence {
        val bounded = readAtMost(stream, MAX_NATIVE_TRACE_BYTES)
        return TraceEvidence(
            summarizeNativeTombstone(bounded.bytes, maximumChars),
            if (bounded.bytes.isEmpty()) "none" else "native_tombstone_protobuf",
            bounded.bytes.size,
            bounded.truncated,
        )
    }

    internal fun summarizeNativeTombstone(value: ByteArray, maximum: Int): String {
        if (value.isEmpty() || maximum <= 0) return ""
        val boundedValue = if (value.size > MAX_NATIVE_TRACE_BYTES) {
            value.copyOf(MAX_NATIVE_TRACE_BYTES)
        } else {
            value
        }
        val tombstone = parseNativeTombstone(boundedValue)
        val signals = listOfNotNull(tombstone.signal, tombstone.signalCode).distinct().take(4)
        val reasons = listOfNotNull(tombstone.reason)
        val libraries = tombstone.frames.mapNotNull(NativeFrameEvidence::module).distinct().take(10)
        val buildIds = tombstone.frames.mapNotNull(NativeFrameEvidence::buildId).distinct().take(10)
        val threads = listOfNotNull(tombstone.thread)
        val symbols = tombstone.frames.mapNotNull(NativeFrameEvidence::function).distinct().take(10)
        val frameLocations = tombstone.frames.map {
            "${it.module.orEmpty()}@${it.relativePc.toString(16)}#${it.buildId.orEmpty()}"
        }
        val signatureInput = listOf(
            signals,
            reasons,
            libraries,
            buildIds,
            threads,
            symbols,
            frameLocations,
        )
            .flatten()
            .joinToString("|")
        val signatureBytes = if (signatureInput.isEmpty()) {
            boundedValue.take(4_096).toByteArray()
        } else {
            signatureInput.toByteArray(Charsets.UTF_8)
        }
        val signature = MessageDigest.getInstance("SHA-256")
            .digest(signatureBytes)
            .take(8)
            .joinToString("") { "%02x".format(it) }
        val lines = buildList {
            // "signature" is intentionally a credential-redaction keyword.
            // This is a short hash of allowlisted crash evidence, not a token.
            add("native_tombstone_protobuf fingerprint=$signature")
            add("thread_selection=${tombstone.selection}")
            add("parser_status=${tombstone.parserStatus}")
            if (signals.isNotEmpty()) add("signals=${signals.joinToString(",")}")
            if (reasons.isNotEmpty()) add("reason=${reasons.joinToString(",")}")
            if (threads.isNotEmpty()) add("threads=${threads.joinToString(",")}")
            if (libraries.isNotEmpty()) add("libraries=${libraries.joinToString(",")}")
            tombstone.frames.take(12).forEachIndexed { index, frame ->
                add(
                    "frame_$index rel_pc=0x${frame.relativePc.toString(16)}" +
                        listOfNotNull(
                            frame.module?.let { "module=$it" },
                            frame.buildId?.let { "build_id=${it.chunked(4).joinToString("-")}" },
                            frame.function?.let { "function=$it" },
                        ).joinToString(" ", prefix = " "),
                )
            }
        }.joinToString("\n")
        return lines.take(maximum)
    }

    private fun parseNativeTombstone(value: ByteArray): NativeTombstoneEvidence {
        val reader = ProtoReader(value)
        var crashedTid: Long? = null
        var signal: String? = null
        var signalCode: String? = null
        var reason: String? = null
        var fieldCount = 0
        // Protobuf field order is not guaranteed. First obtain Tombstone.tid
        // (AOSP field 6), then scan every bounded map entry in field 16. Never
        // substitute an arbitrary waiting thread for the actual crash stack.
        while (!reader.finished && fieldCount++ < MAX_NATIVE_PROTO_FIELDS) {
            val field = reader.next { it == 10 || it == 15 } ?: break
            when {
                field.number == 6 && field.varint != null -> {
                    crashedTid = field.varint.takeIf { it in 1..0xffffffffL }
                }
                field.number == 10 && field.bytes != null -> {
                    val parsed = parseSignal(field.bytes)
                    signal = parsed.first
                    signalCode = parsed.second
                }
                field.number == 15 && field.bytes != null -> reason = parseCause(field.bytes)
            }
        }
        var parserStatus = when {
            reader.malformed -> "incomplete_or_malformed"
            !reader.finished -> "field_limit_reached"
            else -> "complete"
        }
        var thread: ParsedThread? = null
        if (crashedTid != null) {
            val threadReader = ProtoReader(value)
            var threadFieldCount = 0
            while (!threadReader.finished && threadFieldCount++ < MAX_NATIVE_PROTO_FIELDS) {
                val field = threadReader.next { it == 16 } ?: break
                if (field.number != 16 || field.bytes == null) continue
                val entry = parseThreadEntry(field.bytes)
                if (entry == null) {
                    parserStatus = "incomplete_or_malformed"
                } else if (entry.first == crashedTid) {
                    thread = parseThread(entry.second)
                    if (thread.id != null && thread.id != crashedTid) {
                        // A contradictory map key/Thread.id is not trustworthy.
                        thread = null
                        parserStatus = "incomplete_or_malformed"
                    } else if (!thread.complete) {
                        parserStatus = "incomplete_or_malformed"
                    }
                    break
                }
            }
        }
        val selection = when {
            crashedTid == null -> "faulting_tid_missing"
            thread == null -> "faulting_thread_missing"
            thread.frames.isEmpty() -> "faulting_thread_no_frames"
            else -> "exact_tid"
        }
        return NativeTombstoneEvidence(
            signal, signalCode, reason, thread?.name, thread?.frames.orEmpty(),
            selection, parserStatus,
        )
    }

    private fun parseSignal(value: ByteArray): Pair<String?, String?> {
        val reader = ProtoReader(value)
        var signal: String? = null
        var code: String? = null
        repeat(32) {
            val field = reader.next() ?: return@repeat
            if (field.bytes != null) {
                val candidate = safeProtoString(field.bytes, 48)
                if (field.number == 2 && candidate?.matches(Regex("SIG[A-Z0-9]+")) == true) signal = candidate
                if (field.number == 4 && candidate?.matches(Regex("[A-Z0-9_]+")) == true) code = candidate
            }
        }
        return signal to code
    }

    private fun parseCause(value: ByteArray): String? {
        val reader = ProtoReader(value)
        repeat(24) {
            val field = reader.next() ?: return@repeat
            if (field.number == 1 && field.bytes != null) {
                val description = safeProtoString(field.bytes, 160).orEmpty().lowercase()
                return when {
                    "null pointer dereference" in description -> "null_pointer_dereference"
                    "stack overflow" in description -> "stack_overflow"
                    "destroyed mutex" in description -> "destroyed_mutex"
                    "fortify" in description -> "fortify_abort"
                    else -> null
                }
            }
        }
        return null
    }

    private fun parseThreadEntry(value: ByteArray): Pair<Long, ByteArray>? {
        val reader = ProtoReader(value)
        var tid: Long? = null
        var thread: ByteArray? = null
        var fields = 0
        while (!reader.finished && fields++ < MAX_NATIVE_PROTO_FIELDS) {
            val field = reader.next { it == 2 } ?: break
            if (field.number == 1) tid = field.varint
            if (field.number == 2 && field.bytes != null) thread = field.bytes
        }
        if (reader.malformed || !reader.finished || tid == null || tid !in 1..0xffffffffL) return null
        return thread?.let { tid to it }
    }

    private fun parseThread(value: ByteArray): ParsedThread {
        val reader = ProtoReader(value)
        var id: Long? = null
        var name: String? = null
        val frames = mutableListOf<NativeFrameEvidence>()
        var fields = 0
        while (!reader.finished && fields++ < MAX_NATIVE_PROTO_FIELDS) {
            val field = reader.next { it == 2 || (it == 4 && frames.size < 12) } ?: break
            if (field.number == 1) {
                id = field.varint
            } else if (field.number == 2 && field.bytes != null) {
                name = safeThreadCategory(safeProtoString(field.bytes, 80))
            } else if (field.number == 4 && field.bytes != null && frames.size < 12) {
                parseFrame(field.bytes)?.let(frames::add)
            }
        }
        return ParsedThread(id, name, frames, !reader.malformed && reader.finished)
    }

    private fun parseFrame(value: ByteArray): NativeFrameEvidence? {
        val reader = ProtoReader(value)
        var relativePc = 0L
        var module: String? = null
        var function: String? = null
        var buildId: String? = null
        repeat(32) {
            val field = reader.next() ?: return@repeat
            when {
                field.number == 1 && field.varint != null -> relativePc = field.varint.coerceAtMost(0xffffffffffffL)
                field.number == 4 && field.bytes != null -> function = safeFunction(safeProtoString(field.bytes, 160))
                field.number == 6 && field.bytes != null -> module = safeModule(safeProtoString(field.bytes, 180))
                field.number == 8 && field.bytes != null -> buildId = safeBuildId(safeProtoString(field.bytes, 80))
            }
        }
        if (relativePc == 0L && module == null && function == null && buildId == null) return null
        return NativeFrameEvidence(relativePc, module, function, buildId)
    }

    private fun safeProtoString(value: ByteArray, maximum: Int): String? {
        if (value.isEmpty() || value.size > maximum) return null
        if (value.any { byte -> (byte.toInt() and 0xff) !in 0x20..0x7e }) return null
        return value.toString(Charsets.US_ASCII)
    }

    private fun safeModule(value: String?): String? {
        val basename = value?.substringAfterLast('/')?.substringAfterLast('\\') ?: return null
        return basename.takeIf { it.length <= 100 && it.matches(Regex("(?:lib)?[A-Za-z0-9_.+-]+\\.so")) }
    }

    private fun safeFunction(value: String?): String? = value?.takeIf {
        it.length <= 160 && it.matches(Regex("[A-Za-z0-9_<>~:.$+@-]+"))
    }?.replace("::", ".")

    private fun safeBuildId(value: String?): String? = value?.takeIf {
        it.matches(Regex("[A-Fa-f0-9]{8,64}"))
    }

    private fun safeThreadCategory(value: String?): String? = when {
        value == "main" -> "main"
        value == "RenderThread" -> "RenderThread"
        value?.startsWith("flutter-worker-") == true -> "flutter-worker"
        value?.startsWith("SurfaceSyncGroup") == true -> "SurfaceSyncGroup"
        value?.startsWith("WebSocketClient") == true -> "WebSocketClient"
        value?.startsWith("binder:") == true -> "binder"
        value == "queued-work-loop" -> value
        value == "TracingMuxer" -> value
        value == "DartWorker" -> value
        value?.startsWith("mali-compiler") == true -> "mali-compiler"
        value?.startsWith("mpv") == true -> "mpv"
        value?.startsWith("Discord") == true -> "Discord"
        else -> null
    }

    private data class ParsedThread(
        val id: Long?,
        val name: String?,
        val frames: List<NativeFrameEvidence>,
        val complete: Boolean,
    )

    private data class ProtoField(val number: Int, val varint: Long? = null, val bytes: ByteArray? = null)

    private class ProtoReader(private val value: ByteArray) {
        private var offset = 0
        var malformed = false
            private set
        val finished: Boolean get() = offset >= value.size

        fun next(retainBytes: (Int) -> Boolean = { true }): ProtoField? {
            if (finished) return null
            val key = readVarint() ?: return fail()
            val rawNumber = key ushr 3
            if (rawNumber !in 1..0x1fffffffL) return fail()
            val number = rawNumber.toInt()
            val wire = (key and 7).toInt()
            return when (wire) {
                0 -> ProtoField(number, varint = readVarint() ?: return fail())
                1 -> skip(8)?.let { ProtoField(number) }
                2 -> {
                    val rawLength = readVarint() ?: return fail()
                    if (rawLength < 0 || rawLength > value.size - offset) return fail()
                    val length = rawLength.toInt()
                    val bytes = if (retainBytes(number)) value.copyOfRange(offset, offset + length) else null
                    offset += length
                    ProtoField(number, bytes = bytes)
                }
                5 -> skip(4)?.let { ProtoField(number) }
                else -> fail()
            }
        }

        private fun fail(): ProtoField? {
            malformed = true
            offset = value.size
            return null
        }

        private fun readVarint(): Long? {
            var result = 0L
            for (shift in 0..63 step 7) {
                if (offset >= value.size) return null
                val byte = value[offset++].toInt() and 0xff
                if (shift == 63 && byte > 1) return null
                result = result or ((byte and 0x7f).toLong() shl shift)
                if (byte and 0x80 == 0) return result
            }
            return null
        }

        private fun skip(count: Int): Unit? {
            if (count > value.size - offset) {
                fail()
                return null
            }
            offset += count
            return Unit
        }
    }

    private data class BoundedBytes(val bytes: ByteArray, val truncated: Boolean)

    internal data class TraceEvidence(
        val text: String,
        val format: String,
        val rawBytes: Int,
        val truncated: Boolean,
    )

    internal data class CrashBreadcrumb(val code: String, val occurredAtMillis: Long)

    private data class NativeFrameEvidence(
        val relativePc: Long,
        val module: String?,
        val function: String?,
        val buildId: String?,
    )

    private data class NativeTombstoneEvidence(
        val signal: String?,
        val signalCode: String?,
        val reason: String?,
        val thread: String?,
        val frames: List<NativeFrameEvidence>,
        val selection: String,
        val parserStatus: String,
    )

    @RequiresApi(Build.VERSION_CODES.R)
    private fun exitDetails(
        context: Context,
        exit: ApplicationExitInfo,
        trace: TraceEvidence,
        maximum: Int,
    ): String {
        val processTimeline = runCatching {
            breadcrumbContextFromProcessSummary(exit.processStateSummary, exit.timestamp)
        }.getOrDefault("")
        val contextLines = listOf(
            "exit_context reason=${exitReasonName(exit.reason)} " +
                "reason_code=${exit.reason.coerceIn(0, 999)} " +
                "status=${exit.status.coerceIn(-999, 999)} " +
                "importance=${importanceName(exit.importance)} " +
                "pss_mb=${memoryMegabytes(exit.pss)} rss_mb=${memoryMegabytes(exit.rss)} " +
                "trace_format=${trace.format} trace_bytes=${trace.rawBytes.coerceIn(0, MAX_TEXT_TRACE_BYTES)} " +
                "trace_truncated=${trace.truncated}",
            processTimeline.ifEmpty { currentBreadcrumbContext(context, exit.timestamp) },
            sanitize(exit.description.orEmpty(), 500)
                .takeIf { it.isNotEmpty() }
                ?.let { "exit_description=$it" }
                .orEmpty(),
        )
        return composeCrashDetails(contextLines, trace.text, maximum)
    }

    internal fun composeCrashDetails(
        contextLines: List<String>,
        trace: String,
        maximum: Int,
    ): String {
        if (maximum <= 0) return ""
        val context = contextLines
            .asSequence()
            .map { sanitize(it, 700) }
            .filter { it.isNotEmpty() }
            .take(8)
            .joinToString("\n")
        val safeTrace = sanitizeStack(trace, maximum)
        val combined = when {
            context.isEmpty() -> safeTrace
            safeTrace.isEmpty() -> context
            else -> "$context\ntrace:\n$safeTrace"
        }
        return combined.take(maximum)
    }

    private fun currentProcessContext(): String {
        val runtime = Runtime.getRuntime()
        val usedHeap = (runtime.totalMemory() - runtime.freeMemory()).coerceAtLeast(0L)
        val processState = ActivityManager.RunningAppProcessInfo()
        runCatching { ActivityManager.getMyMemoryState(processState) }
        return "process_context importance=${importanceName(processState.importance)} " +
            "pss_mb=${memoryMegabytes(runCatching { Debug.getPss() }.getOrDefault(0L))} " +
            "java_heap_used_mb=${bytesMegabytes(usedHeap)} " +
            "java_heap_committed_mb=${bytesMegabytes(runtime.totalMemory())} " +
            "java_heap_limit_mb=${bytesMegabytes(runtime.maxMemory())} " +
            "native_heap_mb=${bytesMegabytes(Debug.getNativeHeapAllocatedSize())}"
    }

    private fun memoryMegabytes(kilobytes: Long): Long =
        if (kilobytes <= 0L) 0L else ((kilobytes + 512L) / 1_024L).coerceAtMost(1_048_576L)

    private fun bytesMegabytes(bytes: Long): Long =
        if (bytes <= 0L) 0L else ((bytes + 524_288L) / 1_048_576L).coerceAtMost(1_048_576L)

    private fun exitReasonName(reason: Int): String = when (reason) {
        ApplicationExitInfo.REASON_CRASH -> "java_crash"
        ApplicationExitInfo.REASON_CRASH_NATIVE -> "native_crash"
        ApplicationExitInfo.REASON_ANR -> "anr"
        else -> "other"
    }

    internal fun importanceName(importance: Int): String = when {
        importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND -> "foreground"
        importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND_SERVICE ->
            "foreground_service"
        importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_VISIBLE -> "visible"
        importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_PERCEPTIBLE -> "perceptible"
        importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_SERVICE -> "service"
        importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_CACHED -> "cached"
        else -> "unknown"
    }

    private fun isGzip(value: ByteArray): Boolean =
        value.size >= 2 && (value[0].toInt() and 0xff) == 0x1f && (value[1].toInt() and 0xff) == 0x8b

    private fun looksLikeText(value: ByteArray): Boolean {
        if (value.isEmpty()) return false
        var printable = 0
        var inspected = 0
        for (byte in value.take(4_096)) {
            val code = byte.toInt() and 0xff
            if (code == 0) return false
            if (code == 0x09 || code == 0x0a || code == 0x0d || code in 0x20..0x7e) {
                printable++
            }
            inspected++
        }
        return inspected > 0 && printable * 100 / inspected >= 85
    }

    private fun safeTextTrace(value: ByteArray, maximum: Int): String =
        summarizeTextTrace(value.toString(Charsets.UTF_8), maximum)

    /**
     * Keeps the actionable part of an Android text trace.
     *
     * ART commonly prefixes an ANR with tens of kilobytes of GC statistics.
     * A simple first-N-lines truncation therefore loses the `main` thread. We
     * retain a tiny process header and prioritize the main-thread block. If a
     * vendor emits an unfamiliar format, the bounded head/tail fallback is
     * still more useful than returning only the runtime preamble.
     */
    internal fun summarizeTextTrace(value: String, maximum: Int): String {
        if (value.isEmpty() || maximum <= 0) return ""
        val lines = value
            .replace("\r\n", "\n")
            .replace('\r', '\n')
            .lineSequence()
            .toList()
        if (lines.isEmpty()) return ""

        val selected = mutableListOf<String>()
        selected += lines.asSequence().filter { it.isNotBlank() }.take(5)

        val threadHeader = Regex("^\"[^\"]{1,160}\"(?:\\s|$)")
        val mainIndex = lines.indexOfFirst {
            it == "\"main\"" || it.startsWith("\"main\" ")
        }
        if (mainIndex >= 0) {
            val nextThread = (mainIndex + 1 until lines.size)
                .firstOrNull { threadHeader.containsMatchIn(lines[it]) }
                ?: lines.size
            selected += lines.subList(mainIndex, nextThread).take(43)
        } else {
            val signalLines = lines.asSequence()
                .filter {
                    val lower = it.lowercase()
                    lower.contains("anr in ") ||
                        lower.contains("waiting to lock") ||
                        lower.contains("held by thread") ||
                        lower.contains("native method") ||
                        lower.contains("dev.animetv.anime_tv") ||
                        lower.contains("io.flutter")
                }
                .take(25)
                .toList()
            if (signalLines.isNotEmpty()) {
                selected += signalLines
            } else {
                selected += lines.take(23)
                selected += lines.takeLast(22)
            }
        }
        return sanitizeStack(selected.joinToString("\n"), maximum)
    }

    private fun binaryTraceSignature(value: ByteArray): String =
        "binary_trace signature=${shortDigest(value.take(4_096).toByteArray())}"

    private fun shortDigest(value: ByteArray): String = MessageDigest.getInstance("SHA-256")
        .digest(value)
        .take(8)
        .joinToString("") { "%02x".format(it) }

    internal fun boundBreadcrumbs(
        values: List<CrashBreadcrumb>,
        nowMillis: Long,
    ): List<CrashBreadcrumb> {
        val cutoff = nowMillis - BREADCRUMB_HISTORY_MILLIS
        return values
            .asSequence()
            .filter {
                it.code in BREADCRUMB_CODES && it.occurredAtMillis in cutoff..nowMillis
            }
            .sortedBy(CrashBreadcrumb::occurredAtMillis)
            .toList()
            .takeLast(MAX_BREADCRUMBS)
    }

    private fun encodeBreadcrumbs(values: List<CrashBreadcrumb>): String {
        val array = JSONArray()
        values.forEach { breadcrumb ->
            array.put(
                JSONObject()
                    .put("code", breadcrumb.code)
                    .put("at_ms", breadcrumb.occurredAtMillis),
            )
        }
        return array.toString()
    }

    private fun decodeBreadcrumbs(value: String?): List<CrashBreadcrumb> {
        if (value.isNullOrBlank()) return emptyList()
        return runCatching {
            val array = JSONArray(value)
            buildList {
                for (index in 0 until minOf(array.length(), MAX_BREADCRUMBS)) {
                    val item = array.optJSONObject(index) ?: continue
                    val code = item.optString("code")
                    val timestamp = item.optLong("at_ms", 0L)
                    if (code in BREADCRUMB_CODES && timestamp > 0L) {
                        add(CrashBreadcrumb(code, timestamp))
                    }
                }
            }
        }.getOrDefault(emptyList())
    }

    private fun encodeProcessStateSummary(values: List<CrashBreadcrumb>): ByteArray {
        val encoded = buildString {
            append("v1|")
            values.takeLast(6).forEachIndexed { index, value ->
                if (index > 0) append(',')
                append(BREADCRUMB_CODES.getValue(value.code))
                append('@')
                append(value.occurredAtMillis)
            }
        }.toByteArray(Charsets.US_ASCII)
        return encoded.take(MAX_PROCESS_STATE_BYTES).toByteArray()
    }

    private fun currentBreadcrumbContext(context: Context, occurredAtMillis: Long): String {
        val preferences = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return breadcrumbContext(
            decodeBreadcrumbs(preferences.getString(BREADCRUMBS_KEY, null)),
            occurredAtMillis,
        )
    }

    internal fun breadcrumbContext(
        values: List<CrashBreadcrumb>,
        occurredAtMillis: Long,
    ): String {
        val bounded = boundBreadcrumbs(values, occurredAtMillis)
        if (bounded.isEmpty()) return ""
        return "lifecycle_timeline=" + bounded.joinToString(",") { breadcrumb ->
            val age = (occurredAtMillis - breadcrumb.occurredAtMillis)
                .coerceIn(0L, BREADCRUMB_HISTORY_MILLIS)
            "${breadcrumb.code}:-${age}ms"
        }
    }

    internal fun breadcrumbContextFromProcessSummary(
        value: ByteArray?,
        occurredAtMillis: Long,
    ): String {
        if (value == null || value.isEmpty() || value.size > MAX_PROCESS_STATE_BYTES) return ""
        val encoded = value.toString(Charsets.US_ASCII)
        if (!encoded.startsWith("v1|")) return ""
        val reverseCodes = BREADCRUMB_CODES.entries.associate { (event, compact) -> compact to event }
        val values = encoded.removePrefix("v1|")
            .split(',')
            .take(6)
            .mapNotNull { item ->
                val compact = item.substringBefore('@')
                val timestamp = item.substringAfter('@', "").toLongOrNull()
                val event = reverseCodes[compact]
                if (event == null || timestamp == null) null else CrashBreadcrumb(event, timestamp)
            }
        return breadcrumbContext(values, occurredAtMillis)
    }

    private val BREADCRUMB_CODES = linkedMapOf(
        "app_process_created" to "pc",
        "activity_created" to "ac",
        "activity_resumed" to "ar",
        "activity_paused" to "ap",
        "activity_destroyed" to "ad",
        "direct_torrent_bridge_start_requested" to "dbs",
        "direct_torrent_bridge_start_failed" to "dbf",
        "direct_torrent_bridge_stop_requested" to "dbx",
        "direct_torrent_service_created" to "dsc",
        "direct_torrent_service_foreground" to "dsf",
        "direct_torrent_service_destroyed" to "dsd",
        "offline_download_service_created" to "osc",
        "offline_download_service_foreground" to "osf",
        "offline_download_service_destroyed" to "osd",
        "external_playback_service_created" to "esc",
        "external_playback_service_destroyed" to "esd",
    )

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
