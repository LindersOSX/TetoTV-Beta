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
