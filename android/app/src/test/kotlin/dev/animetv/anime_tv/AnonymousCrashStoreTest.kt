package dev.animetv.anime_tv

import android.app.ApplicationExitInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream

class AnonymousCrashStoreTest {
    @Test
    fun `only crash and ANR exit reasons are reportable`() {
        assertTrue(AnonymousCrashStore.isReportableReason(ApplicationExitInfo.REASON_CRASH))
        assertTrue(AnonymousCrashStore.isReportableReason(ApplicationExitInfo.REASON_CRASH_NATIVE))
        assertTrue(AnonymousCrashStore.isReportableReason(ApplicationExitInfo.REASON_ANR))
        assertFalse(AnonymousCrashStore.isReportableReason(ApplicationExitInfo.REASON_EXIT_SELF))
        assertFalse(AnonymousCrashStore.isReportableReason(ApplicationExitInfo.REASON_USER_REQUESTED))
    }

    @Test
    fun `native descriptions are redacted and bounded`() {
        val output = AnonymousCrashStore.sanitize(
            "failed https://private.example/watch Bearer secret token=private " +
                "magnet:?xt=urn:btih:123 ${"a".repeat(64)}\nnext",
            140,
        )

        assertTrue(output.contains("[URL]"))
        assertTrue(output.contains("Bearer [REDACTED]"))
        assertTrue(output.contains("[MAGNET]"))
        assertFalse(output.contains("private.example"))
        assertFalse(output.contains("token=private"))
        assertFalse(output.contains("secret"))
        assertFalse(output.contains("a".repeat(40)))
        assertTrue(output.length <= 140)
    }

    @Test
    fun `native redactor removes scheme-less and JSON-escaped URLs only`() {
        val output = AnonymousCrashStore.sanitize(
            "fetch cdn.private.example:8443/user/alice/video.m3u8 " +
                "{\"url\":\"https:\\/\\/edge.private.example\\/signed\\/video.m3u8\"} " +
                "keep libmpv.so version 1.2.3 dev.animetv.Player",
            1_000,
        )

        assertEquals(2, Regex("\\[URL\\]").findAll(output).count())
        assertFalse(output.contains("cdn.private.example"))
        assertFalse(output.contains("edge.private.example"))
        assertTrue(output.contains("libmpv.so"))
        assertTrue(output.contains("version 1.2.3"))
        assertTrue(output.contains("dev.animetv.Player"))
    }

    @Test
    fun `native descriptions redact local paths but preserve stack class names`() {
        val output = AnonymousCrashStore.sanitize(
            "content://com.android.providers.media.documents/document/video%3Aprivate-show.mkv\n" +
                "file:///storage/emulated/0/Private%20Episode.mkv\n" +
                "teto+private:document-id-episode-42\n" +
                "/storage/emulated/0/Private Show Episode 7.mkv\n" +
                "C:\\Users\\Viewer\\Videos\\Private Episode 8.mkv\n" +
                "at dev.animetv.anime_tv.MainActivity.onDestroy" +
                "(MainActivity.kt:169)",
            1_000,
        )

        assertTrue(output.contains("[URI]"))
        assertTrue(output.contains("[PATH]"))
        assertFalse(output.contains("private-show"))
        assertFalse(output.contains("document-id-episode-42"))
        assertFalse(output.contains("Private Show Episode 7.mkv"))
        assertFalse(output.contains("Private Episode 8.mkv"))
        assertTrue(
            output.contains(
                "dev.animetv.anime_tv.MainActivity.onDestroy" +
                    "(MainActivity.kt:169)",
            ),
        )
    }

    @Test
    fun `local crash summary ring keeps only 48 hours and is bounded`() {
        val now = 1_800_000_000_000L
        val summaries = buildList {
            add(
                mapOf<String, Any?>(
                    "kind" to "native",
                    "message" to "outside",
                    "occurred_at_ms" to now - (49L * 60L * 60L * 1_000L),
                ),
            )
            repeat(15) { index ->
                add(
                    mapOf<String, Any?>(
                        "kind" to "java",
                        "message" to "crash-$index",
                        "occurred_at_ms" to now - ((15L - index) * 1_000L),
                    ),
                )
            }
        }

        val bounded = AnonymousCrashStore.boundLocalCrashSummaries(summaries, now)
        val history = AnonymousCrashStore.boundLocalCrashSummaryHistory(summaries, now)

        assertEquals(12, bounded.size)
        assertEquals("crash-3", bounded.first()["message"])
        assertEquals("crash-14", bounded.last()["message"])
        assertEquals(1, history.droppedOutsideWindow)
        assertEquals(3, history.droppedForCapacity)
    }

    @Test
    fun `native crash summaries redact watch room source and identity context`() {
        val output = AnonymousCrashStore.sanitize(
            "room_code=23456789 capability=private display_name=Alice " +
                "tracker_id=9988 source_id=raw-source user@example.com 192.168.1.20 " +
                "0123456789abcdef0123456789abcdef",
            1_000,
        )

        assertFalse(output.contains("23456789"))
        assertFalse(output.contains("private"))
        assertFalse(output.contains("Alice"))
        assertFalse(output.contains("9988"))
        assertFalse(output.contains("raw-source"))
        assertFalse(output.contains("user@example.com"))
        assertFalse(output.contains("192.168.1.20"))
        assertFalse(output.contains("0123456789abcdef"))
    }

    @Test
    fun `native redactor covers standalone rooms signed paths auth and networks`() {
        val base32Hash = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
        val output = AnonymousCrashStore.sanitize(
            "join 23456789 //cdn.example/video?X-Amz-Signature=private " +
                "edge.example/file?sig=private root.example?signature=root-private " +
                "\"Cookie\":\"session=private-cookie\"\n" +
                "\"display_name\":\"Quoted Viewer\"\n" +
                "Basic private-basic $base32Hash 2001:db8:85a3::8a2e:370:7334 " +
                "::ffff:192.0.2.128 01:23:45:67:89:ab fe80::1%private-zone",
            2_000,
        )

        listOf(
            "23456789",
            "cdn.example",
            "edge.example",
            "root.example",
            "root-private",
            "private-cookie",
            "Quoted Viewer",
            "private-basic",
            base32Hash,
            "2001:db8:85a3::8a2e:370:7334",
            "::ffff:192.0.2.128",
            "01:23:45:67:89:ab",
            "private-zone",
        ).forEach { privateValue -> assertFalse(output.contains(privateValue)) }
        assertTrue(output.contains("[ROOM CODE]"))
        assertTrue(output.contains("[URL]"))
        assertTrue(output.contains("[REDACTED]"))
        assertTrue(output.contains("[NETWORK ADDRESS]"))
    }

    @Test
    fun `unstructured native tombstone bytes emit a signature only`() {
        val payload = buildList<Byte> {
            addAll(byteArrayOf(0, 1, 2).toList())
            addAll("SIGSEGV".toByteArray().toList())
            add(0)
            addAll("SEGV_MAPERR".toByteArray().toList())
            add(0)
            addAll("null pointer dereference".toByteArray().toList())
            add(0)
            addAll("flutter-worker-3".toByteArray().toList())
            add(0)
            addAll("SurfaceSyncGroup".toByteArray().toList())
            add(0)
            addAll("/data/app/private/lib/arm64/libflutter.so".toByteArray().toList())
            add(0)
            addAll("impeller::RenderPass::GetRenderTargetSize".toByteArray().toList())
            add(0)
            addAll("https://private.example/watch?token=secret".toByteArray().toList())
        }.toByteArray()

        val first = AnonymousCrashStore.summarizeNativeTombstone(payload, 1_800)
        val second = AnonymousCrashStore.summarizeNativeTombstone(payload, 1_800)

        assertEquals(first, second)
        assertTrue(first.contains("native_tombstone_protobuf fingerprint="))
        assertFalse(first.contains("SIGSEGV"))
        assertFalse(first.contains("flutter-worker-3"))
        assertFalse(first.contains("libflutter.so"))
        assertFalse(first.contains("private.example"))
        assertFalse(first.contains("secret"))
        assertFalse(first.contains("/data/app"))
    }

    @Test
    fun `native protobuf tombstone summary is bounded`() {
        val payload = ("SIGSEGV libflutter.so flutter-worker-1 " + "x".repeat(10_000))
            .toByteArray()
        val output = AnonymousCrashStore.summarizeNativeTombstone(payload, 80)

        assertTrue(output.length <= 80)
    }

    @Test
    fun `real tombstone protobuf fields retain only safe frame evidence`() {
        val frame = message(
            varintField(1, 0x1234),
            bytesField(4, "mpv::video::render"),
            bytesField(6, "/data/app/private/files/secret-title/libmpv.so"),
            bytesField(8, "AABBCCDDEEFF0011"),
        )
        val thread = message(
            bytesField(2, "flutter-worker-8"),
            bytesField(4, frame),
        )
        val threadEntry = message(varintField(1, 42), bytesField(2, thread))
        val signal = message(bytesField(2, "SIGSEGV"), bytesField(4, "SEGV_MAPERR"))
        val cause = message(bytesField(1, "null pointer dereference at private episode"))
        val tombstone = message(
            varintField(6, 42),
            bytesField(10, signal),
            bytesField(15, cause),
            bytesField(16, threadEntry),
            bytesField(99, "https://private.example/episode.mkv?token=secret"),
        )

        val output = AnonymousCrashStore.summarizeNativeTombstone(tombstone, 1_800)

        assertTrue(output.contains("signals=SIGSEGV,SEGV_MAPERR"))
        assertTrue(output.contains("reason=null_pointer_dereference"))
        assertTrue(output.contains("threads=flutter-worker"))
        assertTrue(output.contains("rel_pc=0x1234"))
        assertTrue(output.contains("module=libmpv.so"))
        assertTrue(output.contains("function=mpv.video.render"))
        assertTrue(output.contains("build_id=AABB-CCDD-EEFF-0011"))
        assertTrue(output.contains("thread_selection=exact_tid"))
        assertFalse(output.contains("secret-title"))
        assertFalse(output.contains("private.example"))
        assertFalse(output.contains("episode.mkv"))
    }

    @Test
    fun `breadcrumb context accepts only allowlisted recent bounded events`() {
        val now = 1_800_000_000_000L
        val values = buildList {
            add(AnonymousCrashStore.CrashBreadcrumb("private-title", now - 10))
            add(AnonymousCrashStore.CrashBreadcrumb("activity_created", now - 11 * 60_000L))
            repeat(20) { index ->
                add(
                    AnonymousCrashStore.CrashBreadcrumb(
                        "direct_torrent_service_foreground",
                        now - (20 - index),
                    ),
                )
            }
        }

        val bounded = AnonymousCrashStore.boundBreadcrumbs(values, now)
        val context = AnonymousCrashStore.breadcrumbContext(values, now)

        assertEquals(16, bounded.size)
        assertFalse(context.contains("private-title"))
        assertFalse(context.contains("activity_created"))
        assertTrue(context.contains("direct_torrent_service_foreground"))
    }

    @Test
    fun `malformed tombstone protobuf fails closed and remains bounded`() {
        val malformed = byteArrayOf(0x52, 0xff.toByte(), 0xff.toByte(), 0xff.toByte(), 0x7f)
        val output = AnonymousCrashStore.summarizeNativeTombstone(malformed, 80)

        assertTrue(output.startsWith("native_tombstone_protobuf fingerprint="))
        assertTrue(output.length <= 80)
    }

    @Test
    fun `unrelated protobuf strings never enter native crash summary`() {
        val tombstone = message(
            bytesField(70, "DiscordPrivateViewer"),
            bytesField(71, "/storage/private_episode.so"),
            bytesField(72, "https://private.example/source?token=secret"),
        )

        val output = AnonymousCrashStore.summarizeNativeTombstone(tombstone, 1_800)

        assertTrue(output.startsWith("native_tombstone_protobuf fingerprint="))
        assertFalse(output.contains("DiscordPrivateViewer"))
        assertFalse(output.contains("private_episode"))
        assertFalse(output.contains("private.example"))
        assertFalse(output.contains("secret"))
    }

    @Test
    fun `structured native frames survive final crash detail composition`() {
        val frame = message(
            varintField(1, 0x9876),
            bytesField(4, "mpv::video::render"),
            bytesField(6, "/system/lib64/libmpv.so"),
            bytesField(8, "00112233445566778899aabbccddeeff00112233"),
        )
        val thread = message(bytesField(2, "RenderThread"), bytesField(4, frame))
        val tombstone = message(varintField(6, 9), bytesField(16, message(varintField(1, 9), bytesField(2, thread))))
        val summary = AnonymousCrashStore.summarizeNativeTombstone(tombstone, 1_800)

        val composed = AnonymousCrashStore.composeCrashDetails(
            listOf("exit_context reason=native_crash"),
            summary,
            4_000,
        )

        assertTrue(composed.contains("module=libmpv.so"))
        assertTrue(composed.contains("function=mpv.video.render"))
        assertTrue(composed.contains("rel_pc=0x9876"))
        assertTrue(composed.contains("build_id=0011-2233-4455-6677-8899-aabb-ccdd-eeff-0011-2233"))
        assertTrue(composed.contains("fingerprint="))
        assertFalse(composed.contains("[NETWORK ADDRESS]"))
        assertFalse(composed.contains("[URI]"))
    }

    @Test
    fun `faulting thread beyond eight threads and 64 KB is selected exactly`() {
        val fields = mutableListOf(varintField(6, 991))
        // An opaque memory mapping larger than the old per-field 64 KB bound
        // must be skipped without interpreting any of its private bytes.
        fields.add(bytesField(17, ByteArray(70_000) { 0x61 }))
        repeat(300) { index ->
            fields.add(threadEntry(index + 1L, "libutils.so", "ALooper_pollOnce"))
        }
        fields.add(threadEntry(991, "libflutter.so", "impeller::RenderPass"))
        val tombstone = message(*fields.toTypedArray())

        assertTrue(tombstone.size > 64_000)
        val evidence = AnonymousCrashStore.readNativeTrace(ByteArrayInputStream(tombstone), 1_800)

        assertFalse(evidence.truncated)
        assertEquals(tombstone.size, evidence.rawBytes)
        assertTrue(evidence.text.contains("thread_selection=exact_tid"))
        assertTrue(evidence.text.contains("parser_status=complete"))
        assertTrue(evidence.text.contains("function=impeller.RenderPass"))
        assertFalse(evidence.text.contains("ALooper_pollOnce"))
        assertFalse(evidence.text.contains("libutils.so"))
        assertTrue(evidence.text.length <= 1_800)
    }

    @Test
    fun `thread fields may precede faulting tid and map values may precede keys`() {
        val thread = message(
            varintField(1, 71),
            bytesField(2, "main"),
            bytesField(4, message(bytesField(6, "libmpv.so"))),
        )
        val tombstone = message(
            threadEntry(1, "libutils.so", "__epoll_pwait"),
            bytesField(16, message(bytesField(2, thread), varintField(1, 71))),
            varintField(6, 71),
        )

        val output = AnonymousCrashStore.summarizeNativeTombstone(tombstone, 1_800)

        assertTrue(output.contains("thread_selection=exact_tid"))
        assertTrue(output.contains("module=libmpv.so"))
        assertFalse(output.contains("__epoll_pwait"))
    }

    @Test
    fun `missing faulting thread never falsely attributes waiting thread stack`() {
        val tombstone = message(
            varintField(6, 999),
            bytesField(10, message(bytesField(2, "SIGSEGV"), bytesField(4, "SEGV_MAPERR"))),
            threadEntry(42, "libflutter.so", "__epoll_pwait"),
        )

        val output = AnonymousCrashStore.summarizeNativeTombstone(tombstone, 1_800)

        assertTrue(output.contains("thread_selection=faulting_thread_missing"))
        assertTrue(output.contains("signals=SIGSEGV,SEGV_MAPERR"))
        assertFalse(output.contains("frame_0"))
        assertFalse(output.contains("libflutter.so"))
        assertFalse(output.contains("__epoll_pwait"))
    }

    @Test
    fun `missing faulting tid and conflicting thread id fail closed`() {
        val noTid = AnonymousCrashStore.summarizeNativeTombstone(
            threadEntry(42, "libutils.so", "__epoll_pwait"),
            1_800,
        )
        val mismatchedThread = message(
            varintField(1, 43),
            bytesField(4, message(bytesField(6, "libutils.so"))),
        )
        val mismatch = AnonymousCrashStore.summarizeNativeTombstone(
            message(
                varintField(6, 42),
                bytesField(16, message(varintField(1, 42), bytesField(2, mismatchedThread))),
            ),
            1_800,
        )

        assertTrue(noTid.contains("thread_selection=faulting_tid_missing"))
        assertTrue(mismatch.contains("thread_selection=faulting_thread_missing"))
        assertTrue(mismatch.contains("parser_status=incomplete_or_malformed"))
        assertFalse(noTid.contains("frame_0"))
        assertFalse(mismatch.contains("frame_0"))
    }

    @Test
    fun `partial thread and malformed tail never get parsed as unrelated frames`() {
        val correctThread = threadEntry(42, "libmpv.so", "mpv::render")
        val truncated = message(varintField(6, 42), correctThread.copyOf(correctThread.size - 6))
        val malformed = message(
            varintField(6, 42),
            // Invalid wire type followed by an otherwise convincing frame.
            byteArrayOf(0x0f),
            correctThread,
        )

        for (input in listOf(truncated, malformed)) {
            val output = AnonymousCrashStore.summarizeNativeTombstone(input, 1_800)
            assertTrue(output.contains("parser_status=incomplete_or_malformed"))
            assertTrue(output.contains("thread_selection=faulting_thread_missing"))
            assertFalse(output.contains("frame_0"))
            assertFalse(output.contains("libmpv.so"))
        }
    }

    @Test
    fun `native capture remains bounded and reports truncation without raw bytes`() {
        val maximumBytes = AnonymousCrashStore.MAX_NATIVE_TRACE_BYTES
        val payload = message(
            varintField(6, 91),
            threadEntry(1, "libutils.so", "__epoll_pwait"),
            bytesField(17, ByteArray(maximumBytes) { 0x61 }),
            threadEntry(91, "libmpv.so", "mpv::render"),
        )
        val input = ByteArrayInputStream(payload)

        val evidence = AnonymousCrashStore.readNativeTrace(input, 1_800)

        assertTrue(evidence.truncated)
        assertEquals(maximumBytes, evidence.rawBytes)
        assertEquals(payload.size - maximumBytes - 1, input.available())
        assertTrue(evidence.text.contains("thread_selection=faulting_thread_missing"))
        assertTrue(evidence.text.contains("parser_status=incomplete_or_malformed"))
        assertTrue(evidence.text.length <= 1_800)
        assertFalse(evidence.text.contains("__epoll_pwait"))
        assertFalse(evidence.text.contains("a".repeat(40)))
        assertFalse(evidence.text.contains("frame_0"))
    }

    @Test
    fun `native parser enforces work bound for excessive tiny fields`() {
        val tinyFields = message(*Array(65_537) { varintField(70, 0) })
        val payload = message(tinyFields, varintField(6, 42), threadEntry(42, "libmpv.so", "mpv::render"))

        val output = AnonymousCrashStore.summarizeNativeTombstone(payload, 1_800)

        assertTrue(output.contains("parser_status=field_limit_reached"))
        assertTrue(output.contains("thread_selection=faulting_tid_missing"))
        assertFalse(output.contains("frame_0"))
        assertTrue(output.length <= 1_800)
    }

    @Test
    fun `build ids survive privacy pipeline while ordinary credentials remain redacted`() {
        val buildId = "0123456789abcdef0123456789abcdef01234567"
        val frame = message(
            varintField(1, 0x1234),
            bytesField(6, "libflutter.so"),
            bytesField(8, buildId),
            bytesField(4, "x".repeat(160)),
        )
        val tombstone = message(
            varintField(6, 42),
            bytesField(16, message(varintField(1, 42), bytesField(2, bytesField(4, frame)))),
        )
        val summary = AnonymousCrashStore.summarizeNativeTombstone(tombstone, 4_000)
        val output = AnonymousCrashStore.composeCrashDetails(
            listOf("exit_context reason=native_crash"),
            AnonymousCrashStore.sanitizeStack(summary, 4_000),
            4_000,
        )
        val privateValue = AnonymousCrashStore.sanitize(
            "token=$buildId signature=$buildId 01:23:45:67:89:ab",
            1_000,
        )

        assertTrue(output.contains("build_id=${buildId.chunked(4).joinToString("-")}"))
        assertTrue(output.contains("fingerprint="))
        assertFalse(output.contains("[NETWORK ADDRESS]"))
        assertFalse(privateValue.contains(buildId))
        assertFalse(privateValue.contains("01:23:45:67:89:ab"))
    }

    @Test
    fun `text trace summary keeps main thread after long runtime preamble`() {
        val mainHeader = "\"main\" prio=5 tid=1 Native"
        val trace = buildString {
            appendLine("----- pid 5080 at 2026-09-03 11:12:26 -----")
            appendLine("Cmd line: dev.animetv.anime_tv")
            repeat(4_000) { index -> appendLine("GcHistogram$index: 12ms") }
            appendLine(mainHeader)
            appendLine("  | group=\"main\" sCount=1 dsCount=0 flags=1 obj=0x0 self=0x0")
            appendLine("  at android.os.MessageQueue.nativePollOnce(Native method)")
            appendLine("  at io.flutter.embedding.engine.FlutterJNI.nativeSurfaceChanged(Native method)")
            appendLine("\"RenderThread\" daemon prio=7 tid=18 Native")
            appendLine("  at android.view.ThreadedRenderer.nSyncAndDrawFrame(Native method)")
        }
        val mainByteOffset = trace
            .substringBefore(mainHeader)
            .toByteArray(Charsets.UTF_8)
            .size

        assertTrue(mainByteOffset > 64_000)

        val output = AnonymousCrashStore.summarizeTextTrace(trace, 1_800)

        assertTrue(output.contains("\"main\""))
        assertTrue(output.contains("MessageQueue.nativePollOnce"))
        assertTrue(output.contains("FlutterJNI.nativeSurfaceChanged"))
        assertFalse(output.contains("GcHistogram3999"))
        assertTrue(output.length <= 1_800)
    }

    @Test
    fun `foreground service importance is not classified as visible`() {
        assertEquals(
            "foreground_service",
            AnonymousCrashStore.importanceName(125),
        )
        assertEquals("visible", AnonymousCrashStore.importanceName(200))
    }

    @Test
    fun `native trace byte count uses native capture bound instead of smaller text bound`() {
        val native = AnonymousCrashStore.TraceEvidence("", "native_tombstone_protobuf", 900_000, false)
        val nativeAtLimit = native.copy(rawBytes = Int.MAX_VALUE, truncated = true)
        val text = native.copy(format = "text", rawBytes = 900_000)

        assertTrue(AnonymousCrashStore.traceContext(native).contains("trace_bytes=900000"))
        assertTrue(AnonymousCrashStore.traceContext(native).contains("trace_truncated=false"))
        assertTrue(AnonymousCrashStore.traceContext(nativeAtLimit).contains("trace_bytes=1048576"))
        assertTrue(AnonymousCrashStore.traceContext(nativeAtLimit).contains("trace_truncated=true"))
        assertTrue(AnonymousCrashStore.traceContext(text).contains("trace_bytes=512000"))
        assertTrue(AnonymousCrashStore.traceContext(native.copy(rawBytes = -1)).contains("trace_bytes=0"))
    }

    @Test
    fun `clipped report details are explicitly marked without increasing output limits`() {
        val longTrace = (1..70).joinToString("\n") { "frame_$it " + "safe ".repeat(80) }
        val output = AnonymousCrashStore.composeCrashDetails(
            listOf("exit_context reason=native_crash", "lifecycle_timeline=activity_paused:-120ms"),
            longTrace,
            4_000,
        )

        assertTrue(output.startsWith("exit_context reason=native_crash"))
        assertTrue(output.endsWith("\ndetails_truncated=true"))
        assertTrue(output.length <= 4_000)
        assertEquals(1, Regex("details_truncated=true").findAll(output).count())
        assertEquals("complete", AnonymousCrashStore.boundCrashDetails("complete", 100))
        assertEquals("", AnonymousCrashStore.boundCrashDetails("too much", 0))
        assertEquals("", AnonymousCrashStore.boundCrashDetails("too much", -1))
        assertTrue(AnonymousCrashStore.boundCrashDetails(longTrace, 7).length <= 7)
    }

    @Test
    fun `line count and per-line truncation are marked even below overall byte budget`() {
        val manyLines = (1..51).joinToString("\n") { "frame_$it" }
        val longLine = "safe ".repeat(70)
        val full = "at dev.animetv.anime_tv.TetoTvApplication.onCreate(TetoTvApplication.kt:12)"

        for (trace in listOf(manyLines, longLine)) {
            val output = AnonymousCrashStore.sanitizeStack(trace, 4_000)
            assertTrue(output.endsWith("\ndetails_truncated=true"))
            assertTrue(output.length < 4_000)
        }
        assertFalse(AnonymousCrashStore.sanitizeStack(manyLines, 4_000).contains("frame_51"))
        assertEquals(full, AnonymousCrashStore.sanitizeStack(full, 4_000))
    }

    @Test
    fun `clipped context lines and omitted context rows also mark incomplete details`() {
        val longContext = AnonymousCrashStore.composeCrashDetails(listOf("safe ".repeat(150)), "frame", 4_000)
        val manyContexts = AnonymousCrashStore.composeCrashDetails((1..9).map { "context_$it" }, "frame", 4_000)

        for (output in listOf(longContext, manyContexts)) {
            assertTrue(output.endsWith("\ndetails_truncated=true"))
            assertTrue(output.length < 4_000)
            assertTrue(output.contains("frame"))
        }
        assertFalse(manyContexts.contains("context_9"))
    }

    @Test
    fun `crash-time technical context and truncation survive local history privacy pipeline`() {
        val now = 1_800_000_000_000L
        val trace = AnonymousCrashStore.composeCrashDetails(
            listOf(
                "java_context thread=background state=runnable daemon=true interrupted=false",
                "lifecycle_timeline=memory_running_critical:-120ms,activity_paused:-50ms",
                "token=private user@example.com https://private.example/episode",
            ),
            (1..45).joinToString("\n") { "frame_$it " + "safe ".repeat(20) },
            4_000,
        )
        val report = mapOf<String, Any?>(
            "kind" to "java", "message" to "Native failure", "stack" to trace, "occurred_at_ms" to now - 100,
        )
        val saved = AnonymousCrashStore.boundLocalCrashSummaries(listOf(report), now).single()
        val output = saved["stack"].toString()

        assertEquals(now - 100, saved["occurred_at_ms"])
        assertTrue(output.contains("state=runnable daemon=true interrupted=false"))
        assertTrue(output.contains("memory_running_critical:-120ms"))
        assertTrue(output.endsWith("\ndetails_truncated=true"))
        assertTrue(output.length <= 1_800)
        assertEquals(1, Regex("details_truncated=true").findAll(output).count())
        assertFalse(output.contains("private"))
        assertFalse(output.contains("user@example.com"))
    }

    @Test
    fun `Java thread context exports only role state and flags not thread identity`() {
        val thread = Thread("private-user@example.com-title-and-url")
        thread.isDaemon = true

        val output = AnonymousCrashStore.javaThreadContext(thread, false)

        assertEquals("java_context thread=background state=new daemon=true interrupted=false", output)
        assertFalse(output.contains(thread.name))
        assertTrue(AnonymousCrashStore.javaThreadContext(thread, true).startsWith("java_context thread=main "))
        assertEquals(Thread.State.NEW, thread.state)
    }

    @Test
    fun `memory callbacks use fixed OS categories and keep UI hiding distinct from pressure`() {
        val expected = mapOf(
            -1 to null, 0 to null, 4 to null,
            5 to "memory_running_moderate", 9 to "memory_running_moderate",
            10 to "memory_running_low", 14 to "memory_running_low",
            15 to "memory_running_critical", 19 to "memory_running_critical",
            20 to "memory_ui_hidden", 39 to "memory_ui_hidden",
            40 to "memory_trim_background", 59 to "memory_trim_background",
            60 to "memory_trim_moderate", 79 to "memory_trim_moderate",
            80 to "memory_trim_complete", 100 to "memory_trim_complete",
        )
        expected.forEach { (level, event) -> assertEquals("level=$level", event, AnonymousCrashStore.memoryTrimBreadcrumb(level)) }
    }

    @Test
    fun `historic memory breadcrumbs exclude future next-launch context and arbitrary labels`() {
        val crashAt = 1_800_000_000_000L
        val summary = "v1|mrc@${crashAt - 200},muh@${crashAt - 100},pc@${crashAt + 500},private@${crashAt - 50}"
        val output = AnonymousCrashStore.breadcrumbContextFromProcessSummary(summary.toByteArray(), crashAt)

        assertEquals("lifecycle_timeline=memory_running_critical:-200ms,memory_ui_hidden:-100ms", output)
        assertFalse(output.contains("app_process_created"))
        assertFalse(output.contains("private"))
        assertEquals(
            "lifecycle_timeline=memory_low_callback:-1ms",
            AnonymousCrashStore.breadcrumbContext(
                listOf(AnonymousCrashStore.CrashBreadcrumb("memory_low_callback", crashAt - 1)), crashAt,
            ),
        )
    }

    @Test
    fun `signal evidence classifies null near-null and non-null without exporting raw addresses`() {
        val cases = listOf(
            message(varintField(8, 1)) to "null", // Proto3 zero omitted.
            message(varintField(8, 1), varintField(9, 0)) to "null",
            message(varintField(8, 1), varintField(9, 128)) to "near_null_lt4096",
            message(varintField(8, 1), varintField(9, 4095)) to "near_null_lt4096",
            message(varintField(8, 1), varintField(9, 4096)) to "non_null",
            message(varintField(8, 1), varintField(9, 0x7fabcdef1234)) to "non_null",
            message(varintField(8, 1), varintField(9, -1L)) to "non_null",
        )
        cases.forEach { (fields, expected) ->
            val signal = message(
                bytesField(2, "SIGSEGV"), bytesField(4, "SEGV_MAPERR"), fields,
                varintField(6, 874321), varintField(7, 765432),
                bytesField(10, "https://private.example/user?token=private"),
            )
            val output = AnonymousCrashStore.summarizeNativeTombstone(bytesField(10, signal), 1_800)
            assertTrue(output.contains("signals=SIGSEGV,SEGV_MAPERR"))
            assertTrue(output.contains("fault_address_class=$expected"))
            listOf("7fabcdef1234", "140375252668980", "fault_address=", "874321", "765432", "private").forEach {
                assertFalse("Unexpected private field $it", output.contains(it))
            }
        }
    }

    @Test
    fun `missing or incomplete signal address evidence is never called a null dereference`() {
        val incomplete = message(varintField(8, 1), byteArrayOf(0x4a, 0x7f))
        val tooManyFields = message(varintField(8, 1), *Array(40) { varintField(99, 0) })
        for (signal in listOf(varintField(9, 0), message(varintField(8, 0), varintField(9, 128)), incomplete, tooManyFields)) {
            val output = AnonymousCrashStore.summarizeNativeTombstone(bytesField(10, signal), 1_800)
            assertFalse(output.contains("fault_address_class="))
            assertFalse(output.contains("reason=null_pointer_dereference"))
        }
    }

    @Test
    fun `native process uptime is a crash-time duration and not a device or process identifier`() {
        for (uptime in listOf(0L, 3_600L, 0xffffffffL)) {
            val tombstone = message(
                varintField(20, uptime), varintField(5, 874321), varintField(7, 765432),
                bytesField(2, "private-build-fingerprint"), bytesField(9, "private-command-line"),
            )
            val output = AnonymousCrashStore.summarizeNativeTombstone(tombstone, 1_800)
            assertTrue(output.contains("process_uptime_s=$uptime"))
            assertFalse(output.contains("874321"))
            assertFalse(output.contains("765432"))
            assertFalse(output.contains("private"))
        }
        for (tombstone in listOf(byteArrayOf(), varintField(20, -1L), varintField(20, 0x100000000L))) {
            assertFalse(AnonymousCrashStore.summarizeNativeTombstone(tombstone, 1_800).contains("process_uptime_s="))
        }
    }

    @Test
    fun `structured native memory-error kinds survive while allocation metadata stays private`() {
        val kinds = listOf("use_after_free", "double_free", "invalid_free", "buffer_overflow", "buffer_underflow")
        kinds.forEachIndexed { index, kind ->
            val memoryError = message(
                varintField(2, index + 1L),
                bytesField(3, "private-account https://private.example/book 0x7fabcdef1234"),
            )
            // Typed memory-error evidence wins regardless of protobuf field order.
            val cause = message(bytesField(2, memoryError), bytesField(1, "null pointer dereference at private-title"))
            val tombstone = message(bytesField(15, cause), bytesField(15, bytesField(1, "unrecognized private-title")))
            val output = AnonymousCrashStore.summarizeNativeTombstone(tombstone, 1_800)

            assertTrue(output.contains("reason=$kind"))
            assertFalse(output.contains("private"))
            assertFalse(output.contains("7fabcdef1234"))
        }
    }

    @Test
    fun `unknown malformed or excessively nested memory-error evidence fails closed`() {
        val invalidErrors = listOf(
            varintField(2, 0), varintField(2, 99),
            message(varintField(2, 1), byteArrayOf(0x1a, 0x7f)),
            message(varintField(2, 1), *Array(25) { varintField(99, 0) }),
        )
        for (memoryError in invalidErrors) {
            val output = AnonymousCrashStore.summarizeNativeTombstone(bytesField(15, bytesField(2, memoryError)), 1_800)
            assertFalse(output.contains("reason="))
        }
        val malformedCause = message(bytesField(2, varintField(2, 1)), byteArrayOf(0x1a, 0x7f))
        val output = AnonymousCrashStore.summarizeNativeTombstone(bytesField(15, malformedCause), 1_800)
        assertFalse(output.contains("reason="))
    }

    @Test
    fun `crash build metadata accepts bounded release versions and rejects unknown or private values`() {
        assertEquals(
            AnonymousCrashStore.CrashBuildMetadata("2.0.74", 410051),
            AnonymousCrashStore.safeCrashBuildMetadata("2.0.74", 410051),
        )
        assertTrue(AnonymousCrashStore.safeCrashBuildMetadata("2.0.74-beta.1", 410051) != null)
        for (version in listOf(null, "unknown", "0.0.0", "https://private.example", "2.0.74 user@example.com", "2.0.74-" + "x".repeat(40))) {
            assertEquals(null, AnonymousCrashStore.safeCrashBuildMetadata(version, 410051))
        }
        for (build in listOf(null, 0L, -1L, 1_000_000_000L)) {
            assertEquals(null, AnonymousCrashStore.safeCrashBuildMetadata("2.0.74", build))
        }
    }

    @Test
    fun `process snapshot carries original build with whole recent breadcrumbs inside OS byte limit`() {
        val now = 1_800_000_000_000L
        val build = AnonymousCrashStore.CrashBuildMetadata("2.0.69", 410046)
        val breadcrumbs = (1..16).map { AnonymousCrashStore.CrashBreadcrumb("memory_running_critical", now - 20 + it) }
        val snapshot = AnonymousCrashStore.encodeProcessStateSummary(breadcrumbs, build)
        val encoded = snapshot.toString(Charsets.US_ASCII)

        assertTrue(snapshot.size <= 120)
        assertTrue(encoded.startsWith("v2|2.0.69|410046|"))
        assertTrue(encoded.endsWith("mrc@${now - 4}"))
        assertEquals(build, AnonymousCrashStore.buildMetadataFromProcessSummary(snapshot, now))
        assertTrue(AnonymousCrashStore.breadcrumbContextFromProcessSummary(snapshot, now).contains("memory_running_critical:-4ms"))
        assertFalse(encoded.contains("private"))
    }

    @Test
    fun `isolated Aniyomi worker snapshot carries build and only its fixed lifecycle marker`() {
        val workerCreatedAt = 1_800_000_000_000L
        val build = AnonymousCrashStore.CrashBuildMetadata("2.0.74", 410051)

        val snapshot = AnonymousCrashStore.aniyomiWorkerProcessStateSummary(build, workerCreatedAt)
        val encoded = snapshot.toString(Charsets.US_ASCII)

        assertEquals("v2|2.0.74|410051|awc@$workerCreatedAt", encoded)
        assertEquals(
            build,
            AnonymousCrashStore.buildMetadataFromProcessSummary(snapshot, workerCreatedAt + 50),
        )
        assertEquals(
            "lifecycle_timeline=aniyomi_worker_created:-50ms",
            AnonymousCrashStore.breadcrumbContextFromProcessSummary(snapshot, workerCreatedAt + 50),
        )
        for (privateValue in listOf("provider", "extension", "request", "http", "private")) {
            assertFalse(encoded.contains(privateValue, ignoreCase = true))
        }
        assertTrue(snapshot.size <= 120)
    }

    @Test
    fun `isolated Aniyomi worker snapshot fails closed when build metadata is invalid`() {
        val snapshot = AnonymousCrashStore.aniyomiWorkerProcessStateSummary(
            AnonymousCrashStore.CrashBuildMetadata("private-user", 410051),
            occurredAtMillis = 0,
        )

        assertEquals("v2|0.0.0|1|awc@1", snapshot.toString(Charsets.US_ASCII))
        assertEquals(null, AnonymousCrashStore.buildMetadataFromProcessSummary(snapshot, 2))
        assertEquals(
            "lifecycle_timeline=aniyomi_worker_created:-1ms",
            AnonymousCrashStore.breadcrumbContextFromProcessSummary(snapshot, 2),
        )
    }

    @Test
    fun `long safe build versions never get cut into a believable partial snapshot`() {
        val now = 1_800_000_000_000L
        val build = AnonymousCrashStore.CrashBuildMetadata("123.456.789-beta." + "a".repeat(23), 999_999_999)
        val snapshot = AnonymousCrashStore.encodeProcessStateSummary(
            (1..6).map { AnonymousCrashStore.CrashBreadcrumb("memory_running_critical", now - it) }, build,
        )

        assertTrue(snapshot.size <= 120)
        assertEquals(build, AnonymousCrashStore.buildMetadataFromProcessSummary(snapshot, now))
        assertTrue(snapshot.toString(Charsets.US_ASCII).endsWith("@${now - 6}"))
    }

    @Test
    fun `old exit attribution never uses a newer launch snapshot`() {
        val crashAt = 1_800_000_000_000L
        val oldBuild = AnonymousCrashStore.CrashBuildMetadata("2.0.69", 410046)
        val newBuild = AnonymousCrashStore.CrashBuildMetadata("2.0.74", 410051)
        val old = AnonymousCrashStore.encodeProcessStateSummary(
            listOf(AnonymousCrashStore.CrashBreadcrumb("activity_resumed", crashAt - 600_001)), oldBuild,
        )
        val nextLaunch = AnonymousCrashStore.encodeProcessStateSummary(
            listOf(AnonymousCrashStore.CrashBreadcrumb("app_process_created", crashAt + 50)), newBuild,
        )

        // Build attribution remains valid even if no recent lifecycle marker
        // exists; it belongs to this OS exit record, not a timestamp guess.
        assertEquals(oldBuild, AnonymousCrashStore.buildMetadataFromProcessSummary(old, crashAt))
        assertEquals("", AnonymousCrashStore.breadcrumbContextFromProcessSummary(old, crashAt))
        assertEquals(null, AnonymousCrashStore.buildMetadataFromProcessSummary(nextLaunch, crashAt))
    }

    @Test
    fun `legacy process snapshots retain breadcrumbs but have explicitly unknown build provenance`() {
        val crashAt = 1_800_000_000_000L
        val legacy = "v1|ar@${crashAt - 80},mrc@${crashAt - 20}".toByteArray()
        val noBuild = AnonymousCrashStore.encodeProcessStateSummary(
            listOf(AnonymousCrashStore.CrashBreadcrumb("activity_paused", crashAt - 10)), null,
        )

        assertEquals(null, AnonymousCrashStore.buildMetadataFromProcessSummary(legacy, crashAt))
        assertEquals(null, AnonymousCrashStore.buildMetadataFromProcessSummary(noBuild, crashAt))
        assertTrue(AnonymousCrashStore.breadcrumbContextFromProcessSummary(legacy, crashAt).contains("memory_running_critical:-20ms"))
        assertTrue(AnonymousCrashStore.breadcrumbContextFromProcessSummary(noBuild, crashAt).contains("activity_paused:-10ms"))
    }

    @Test
    fun `malformed partial or uncorrelated build snapshots fail closed`() {
        val crashAt = 1_800_000_000_000L
        val invalid = listOf(
            "", "v2|2.0.74|410051", "v2|2.0.74|410051|", "v2|2.0.74|410051|pc@",
            "v2|2.0.74|0|pc@${crashAt - 1}", "v2|private-user|410051|pc@${crashAt - 1}",
            "v2|2.0.74|410051|private@${crashAt - 1}", "v2|2.0.74|410051|pc@0",
            "v2|2.0.74|410051|ar@${crashAt - 1},pc@${crashAt + 1}",
            "v2|2.0.74|410051|" + "x".repeat(121),
        )
        invalid.forEach { assertEquals(null, AnonymousCrashStore.buildMetadataFromProcessSummary(it.toByteArray(), crashAt)) }
        assertEquals(null, AnonymousCrashStore.buildMetadataFromProcessSummary(null, crashAt))
        assertEquals(null, AnonymousCrashStore.buildMetadataFromProcessSummary("v2|2.0.74|410051|pc@1".toByteArray(), 0))
    }

    @Test
    fun `persisted original crash build is preserved during later replay`() {
        val report = mapOf<String, Any?>(
            "report_id" to "java-old-event", "kind" to "java", "stack" to "frame",
            "app_version" to "2.0.69", "build_number" to 410046L,
            "occurred_at_ms" to 1_800_000_000_000L,
        )
        val restored = AnonymousCrashStore.normalizePersistedBuildAttribution(report)

        assertEquals(report, restored)
        assertEquals("2.0.69", restored["app_version"])
        assertEquals(410046L, restored["build_number"])
        assertFalse(restored["stack"].toString().contains("unknown"))
    }

    @Test
    fun `legacy or incomplete queued build metadata receives v1-safe unknown sentinel exactly once`() {
        val variants = listOf(
            emptyMap(), mapOf("app_version" to "2.0.69"), mapOf("build_number" to 410046L),
            mapOf("app_version" to "private-user", "build_number" to 410046L),
            mapOf("app_version" to "2.0.69", "build_number" to 12.5),
            mapOf("app_version" to "2.0.69", "build_number" to Double.NaN),
        )
        variants.forEach { metadata ->
            val report = mapOf<String, Any?>("kind" to "native", "stack" to "frame") + metadata
            val first = AnonymousCrashStore.normalizePersistedBuildAttribution(report)
            val second = AnonymousCrashStore.normalizePersistedBuildAttribution(first)
            assertEquals("0.0.0", first["app_version"])
            assertEquals(1L, first["build_number"])
            assertEquals(first, second)
            assertTrue(first["stack"].toString().startsWith("build_attribution=unknown app_version=0.0.0 build_number=1"))
            assertEquals(setOf("kind", "stack", "app_version", "build_number"), first.keys)
        }
    }

    @Test
    fun `local crash history retains crash-time version fields and unknown attribution across sanitization`() {
        val now = 1_800_000_000_000L
        val original = mapOf<String, Any?>(
            "kind" to "java", "message" to "failure", "stack" to "frame", "occurred_at_ms" to now - 2_000,
            "app_version" to "2.0.69", "build_number" to 410046L,
        )
        val legacy = mapOf<String, Any?>(
            "kind" to "native", "message" to "failure", "stack" to "frame", "occurred_at_ms" to now - 1_000,
        )
        val first = AnonymousCrashStore.boundLocalCrashSummaries(listOf(original, legacy), now)
        val second = AnonymousCrashStore.boundLocalCrashSummaries(first, now + 1_000)

        assertEquals(first, second)
        assertEquals("2.0.69", second[0]["app_version"])
        assertEquals(410046L, second[0]["build_number"])
        assertEquals("0.0.0", second[1]["app_version"])
        assertEquals(1L, second[1]["build_number"])
        assertTrue(second[1]["stack"].toString().contains("build_attribution=unknown"))
    }

    private fun message(vararg fields: ByteArray): ByteArray = fields.flatMap { it.toList() }.toByteArray()

    private fun threadEntry(tid: Long, module: String, function: String): ByteArray = bytesField(
        16,
        message(
            varintField(1, tid),
            bytesField(
                2,
                message(
                    varintField(1, tid),
                    bytesField(2, "main"),
                    bytesField(4, message(bytesField(6, module), bytesField(4, function))),
                ),
            ),
        ),
    )

    private fun bytesField(number: Int, value: String): ByteArray =
        bytesField(number, value.toByteArray(Charsets.US_ASCII))

    private fun bytesField(number: Int, value: ByteArray): ByteArray = message(
        encodeVarint((number shl 3 or 2).toLong()),
        encodeVarint(value.size.toLong()),
        value,
    )

    private fun varintField(number: Int, value: Long): ByteArray = message(
        encodeVarint((number shl 3).toLong()),
        encodeVarint(value),
    )

    private fun encodeVarint(value: Long): ByteArray {
        var remaining = value
        val output = mutableListOf<Byte>()
        do {
            var byte = (remaining and 0x7f).toInt()
            remaining = remaining ushr 7
            if (remaining != 0L) byte = byte or 0x80
            output.add(byte.toByte())
        } while (remaining != 0L)
        return output.toByteArray()
    }
}
