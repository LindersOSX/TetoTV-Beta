package dev.animetv.anime_tv.aniyomi

import android.app.Activity
import android.app.Instrumentation
import android.os.Bundle
import android.os.Process
import android.os.SystemClock
import android.util.Base64
import com.android.apksig.internal.asn1.Asn1Class
import com.android.apksig.internal.asn1.Asn1Field
import dev.animetv.anime_tv.PhoneSetupP256Bridge
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** Runs only in the separately built androidTest APK. No dependency on a provider repository. */
class AniyomiIsolationInstrumentation : Instrumentation() {
    private var inspectMedia3Playback = false
    private var inspectMedia3PublicHttps = false
    private var inspectAuthorizedAnimeGG = false
    private var authorizedAnimeGGPayload: String? = null
    private var inspectAuthorizedAnimeGGStreams = false
    private var inspectAuthorizedKickAssAnime = false
    private var authorizedKickAssAnimePayload: String? = null
    private var inspectAuthorizedKickAssAnimeStreams = false
    private var inspectAuthorizedAnikoto = false
    private var inspectAuthorizedAnikotoCurrent = false
    private var authorizedAnikotoPayload: String? = null
    private var authorizedAnikotoPayloadPart2: String? = null
    private var inspectAuthorizedOneTwoThreeAnime = false
    private var authorizedOneTwoThreeAnimePayload: String? = null
    override fun onCreate(arguments: Bundle?) {
        inspectMedia3Playback = arguments?.getString("media3Playback") == "true"
        inspectMedia3PublicHttps = arguments?.getString("media3PublicHttps") == "true"
        inspectAuthorizedAnimeGG = arguments?.getString("authorizedAnimeGG") == "true"
        authorizedAnimeGGPayload = arguments?.getString("authorizedAnimeGGPayload")
        inspectAuthorizedAnimeGGStreams = arguments?.getString("authorizedAnimeGGStreams") == "true"
        inspectAuthorizedKickAssAnime = arguments?.getString("authorizedKickAssAnime") == "true"
        authorizedKickAssAnimePayload = arguments?.getString("authorizedKickAssAnimePayload")
        inspectAuthorizedKickAssAnimeStreams = arguments?.getString("authorizedKickAssAnimeStreams") == "true"
        inspectAuthorizedAnikotoCurrent = arguments?.getString("authorizedAnikotoCurrent") == "true"
        inspectAuthorizedAnikoto = arguments?.getString("authorizedAnikoto") == "true" || inspectAuthorizedAnikotoCurrent
        authorizedAnikotoPayload = arguments?.getString("authorizedAnikotoPayload")
        authorizedAnikotoPayloadPart2 = arguments?.getString("authorizedAnikotoPayloadPart2")
        inspectAuthorizedOneTwoThreeAnime = arguments?.getString("authorizedOneTwoThreeAnime") == "true"
        authorizedOneTwoThreeAnimePayload = arguments?.getString("authorizedOneTwoThreeAnimePayload")
        super.onCreate(arguments)
        start()
    }
    override fun onStart() {
        val results = Bundle()
        var host: AniyomiNativeHost? = null
        var enabled = true
        val sentinel = File(targetContext.filesDir, "aniyomi-isolation-fixture-sentinel")
        try {
            if (inspectMedia3Playback) {
                results.putString("stream", dev.animetv.anime_tv.player.Media3PlaybackInstrumentation.run(this, inspectMedia3PublicHttps) + "\n")
                finish(Activity.RESULT_OK, results)
                return
            }
            AniyomiHttpReplyInstrumentation.run(targetContext, context)
            results.putString("httpBodyTransport", "PASS: isolated Binder 4-MiB read-only unlinked FD + digest; small Parcel, sender-close, malformed/cancelled read checks")
            checkPhoneSetupCrypto()
            results.putString("phoneSetupCrypto", "PASS: native bridge generated fixed-width P-256 pairs and matching 32-byte ECDH secrets; no session POST or key material output")
            val signatureModel = Class.forName("com.android.apksig.internal.x509.SubjectPublicKeyInfo")
            check(signatureModel.getAnnotation(Asn1Class::class.java) != null)
            check(signatureModel.declaredFields.count { it.getAnnotation(Asn1Field::class.java) != null } == 2)
            results.putString("apkAsn1", "PASS: apksig runtime ASN.1 class and field annotations survive shrinking")
            sentinel.writeText("Generated non-secret isolation canary")
            host = AniyomiNativeHost(targetContext) { enabled }
            host.revoke()
            if (inspectAuthorizedAnikoto || inspectAuthorizedOneTwoThreeAnime) {
                check(inspectAuthorizedAnikoto != inspectAuthorizedOneTwoThreeAnime)
                check(!inspectAuthorizedAnimeGG && !inspectAuthorizedKickAssAnime)
                val summary = if (inspectAuthorizedAnikoto) {
                    // Keep each Android argv element below MAX_ARG_STRLEN.
                    val first = authorizedAnikotoPayload
                    val second = authorizedAnikotoPayloadPart2
                    check(first == null || first.length <= 100_000)
                    check(second == null || second.length <= 100_000)
                    check(second == null || first != null)
                    val payload = first?.let { it + (second ?: "") }
                    inspectAuthorizedProxyFixture(
                        host,
                        if (inspectAuthorizedAnikotoCurrent) "Anikoto 16.8" else "Anikoto 14.6",
                        if (inspectAuthorizedAnikotoCurrent) "authorized-anikoto-16.8.apk" else "authorized-anikoto-14.6.apk",
                        payload,
                        if (inspectAuthorizedAnikotoCurrent) 89_071 else 113_533,
                        if (inspectAuthorizedAnikotoCurrent) "dabc93fa80b03c38cdf5adf0f9cd1b7ce5e9cbb15f282d0b6d815a061474117b"
                            else "002fb7d9b9a59b70bc9fcae20e2f5bf7025f868530e73e20815c28e981236c80",
                        "eu.kanade.tachiyomi.animeextension.en.anikoto", "Anikoto", "4697393375201558791",
                    )
                } else {
                    inspectAuthorizedProxyFixture(
                        host, "123Anime 14.2", "authorized-onetwothreeanime-14.2.apk", authorizedOneTwoThreeAnimePayload,
                        86_069, "25dfdfae67b0f6682f679ad3b58e467617fc0503ac939f417a588ae8ca28564f",
                        "eu.kanade.tachiyomi.animeextension.en.onetwothreeanime", "123Anime", "9168084761765988435",
                    )
                }
                results.putString("stream", summary + "\n")
                finish(Activity.RESULT_OK, results)
                return
            }
            if (inspectAuthorizedKickAssAnime) {
                // Opt-in diagnosis of the exact separately authorized APK only;
                // neither bundled in the app nor accepted as an arbitrary loader.
                val file = File(targetContext.cacheDir, "authorized-kickassanime-14.61.apk")
                authorizedKickAssAnimePayload?.let { payload ->
                    check(payload.length <= 120_000)
                    val bytes = Base64.decode(payload, Base64.NO_WRAP)
                    check(bytes.size == 84_701)
                    val hash = MessageDigest.getInstance("SHA-256").digest(bytes)
                        .joinToString("") { "%02x".format(it.toInt() and 255) }
                    check(hash == "30e73885f6dca68c074523f913393399936ca5bd8152b66858d0fc0b083e03d3")
                    file.writeBytes(bytes)
                }
                val identity = data(await { host.inspectApk(file.absolutePath, "anime", it) })
                check(identity["apkSha256"] == "30e73885f6dca68c074523f913393399936ca5bd8152b66858d0fc0b083e03d3")
                check(identity["certificateSha256"] == "cbec121aa82ebb02aaa73806992e0368a97d47b5451ed6524816d03084c45905")
                check(identity["packageName"] == "eu.kanade.tachiyomi.animeextension.en.kickassanime")
                check(host.approve(identity.getValue("inspectionId") as String)["ok"] == true)
                val extensionId = identity.getValue("extensionId")
                val listed = data(await { host.request(mapOf("extensionId" to extensionId, "operation" to "sources"), it) })
                val source = (listed["sources"] as List<*>).single() as Map<*, *>
                check(source["name"] == "KickAssAnime")
                val response = await { host.request(mapOf("extensionId" to extensionId,
                    "sourceId" to source["id"], "operation" to "search", "query" to "One Piece", "page" to 1), it) }
                check(response["ok"] == true) { "Authorized KickAssAnime multiword search failed: $response" }
                val matches = data(response)["items"] as List<*>
                val count = matches.size
                check(count > 0) { "Authorized KickAssAnime multiword search returned no matches" }
                var streamSummary = "No videos requested."
                if (inspectAuthorizedKickAssAnimeStreams) {
                    // Exact-title/episode matching prevents the smoke test from
                    // silently claiming success with a sequel or unrelated row.
                    val selected = matches.filterIsInstance<Map<*, *>>().firstOrNull {
                        (it["title"] as? String)?.equals("One Piece", ignoreCase = true) == true
                    } ?: error("Authorized KickAssAnime exact title match missing")
                    val detail = data(await { host.request(mapOf("extensionId" to extensionId,
                        "sourceId" to source["id"], "operation" to "details", "url" to selected["url"],
                        "title" to selected["title"]), it) })["item"] as Map<*, *>
                    val episodeData = data(await { host.request(mapOf("extensionId" to extensionId,
                        "sourceId" to source["id"], "operation" to "episodes", "url" to detail["url"],
                        "title" to detail["title"], "targetEpisode" to 1), it) })
                    val episodes = episodeData["chapters"] as List<*>
                    val episode = episodes.filterIsInstance<Map<*, *>>().firstOrNull {
                        (it["number"] as? Number)?.toDouble() == 1.0
                    } ?: error("Authorized KickAssAnime exact episode 1 missing")
                    val videoData = data(await { host.request(mapOf("extensionId" to extensionId,
                        "sourceId" to source["id"], "operation" to "videos", "url" to episode["url"],
                        "title" to episode["name"]), it) })
                    val videoCount = (videoData["videos"] as List<*>).size
                    check(videoCount > 0) { "Authorized KickAssAnime videos returned no playable rows" }
                    streamSummary = "details PASS; episodes PASS (${episodes.size} targeted rows); videos PASS ($videoCount rows). No playback or media download."
                }
                host.revoke()
                file.delete()
                results.putString("stream", "Exact authorized KickAssAnime 14.61: signature/hash verified; isolated source discovery and multiword search PASS ($count rows); $streamSummary Approval revoked.\n")
                finish(Activity.RESULT_OK, results)
                return
            }
            if (inspectAuthorizedAnimeGG) {
                // Explicit diagnostic opt-in, never a bundled provider or a normal-app path.
                // The caller supplies only the exact separately authorized APK in test cache.
                val file = File(targetContext.cacheDir, "authorized-animegg-14.2.apk")
                authorizedAnimeGGPayload?.let { payload ->
                    // Optional adb instrumentation payload avoids needing debuggable/run-as
                    // access for a release-equivalent test. Only this exact authorized APK.
                    check(payload.length <= 40_000)
                    val bytes = Base64.decode(payload, Base64.NO_WRAP)
                    check(bytes.size == 27_278)
                    val hash = MessageDigest.getInstance("SHA-256").digest(bytes)
                        .joinToString("") { "%02x".format(it.toInt() and 255) }
                    check(hash == "18cfab3cf1ba29a41a2fb72a6f34b0b00222fcf98ef2ab36bc37a5ac5c32a4e0")
                    file.writeBytes(bytes)
                }
                val identity = data(await { host.inspectApk(file.absolutePath, "anime", it) })
                check(identity["apkSha256"] == "18cfab3cf1ba29a41a2fb72a6f34b0b00222fcf98ef2ab36bc37a5ac5c32a4e0")
                check(identity["certificateSha256"] == "cbec121aa82ebb02aaa73806992e0368a97d47b5451ed6524816d03084c45905")
                check(identity["packageName"] == "eu.kanade.tachiyomi.animeextension.en.animegg")
                check(host.approve(identity.getValue("inspectionId") as String)["ok"] == true)
                val response = await { host.request(mapOf("extensionId" to identity.getValue("extensionId"),
                    "operation" to "sources"), it) }
                check(response["ok"] == true) { "Authorized AnimeGG source discovery failed: $response" }
                val listed = (data(response)["sources"] as List<*>).single() as Map<*, *>
                check(listed["id"] == "2247987965040486818" && listed["name"] == "AnimeGG")
                var streamSummary = "No content requests made."
                if (inspectAuthorizedAnimeGGStreams) {
                    val extensionId = identity.getValue("extensionId")
                    val sourceId = listed["id"]
                    val searchData = data(await { host.request(mapOf("extensionId" to extensionId,
                        "sourceId" to sourceId, "operation" to "search", "query" to "One Piece", "page" to 1), it) })
                    val matches = searchData["items"] as List<*>
                    val selected = matches.filterIsInstance<Map<*, *>>().firstOrNull {
                        (it["title"] as? String)?.equals("One Piece", ignoreCase = true) == true
                    } ?: error("Authorized AnimeGG exact title match missing")
                    val detailData = data(await { host.request(mapOf("extensionId" to extensionId,
                        "sourceId" to sourceId, "operation" to "details", "url" to selected["url"],
                        "title" to selected["title"]), it) })
                    val detail = detailData["item"] as Map<*, *>
                    check((detail["title"] as? String)?.equals("One Piece", ignoreCase = true) == true) {
                        "Authorized AnimeGG details title mismatch"
                    }
                    val episodeData = data(await { host.request(mapOf("extensionId" to extensionId,
                        "sourceId" to sourceId, "operation" to "episodes", "url" to detail["url"],
                        "title" to detail["title"], "targetEpisode" to 1), it) })
                    val episodes = episodeData["chapters"] as List<*>
                    val episode = episodes.filterIsInstance<Map<*, *>>().firstOrNull {
                        (it["number"] as? Number)?.toDouble() == 1.0
                    } ?: error("Authorized AnimeGG exact episode 1 missing")
                    val videoData = data(await { host.request(mapOf("extensionId" to extensionId,
                        "sourceId" to sourceId, "operation" to "videos", "url" to episode["url"],
                        "title" to episode["name"]), it) })
                    val videoCount = (videoData["videos"] as List<*>).size
                    check(videoCount > 0) {
                        val safeCounts = listOf("originalCount", "discardedVideoCount", "returnedCount")
                            .joinToString { key -> "$key=${(videoData[key] as? Number)?.toInt() ?: -1}" }
                        // The host replaces this map with closed scalar fields;
                        // no provider URL/header/body or raw error is printed.
                        "Authorized AnimeGG videos returned no playable rows ($safeCounts; http=${videoData["httpDiagnostics"]})"
                    }
                    fun bucket(value: Map<String, Any?>): String =
                        (value["broker_response_size_bucket"] as? String)
                            ?.takeIf { it in setOf("none", "lt64k", "64to128k", "128to256k", "over256k") }
                            ?: "unavailable"
                    streamSummary = "search PASS (${matches.size} rows, ${bucket(searchData)}); " +
                        "details PASS (${bucket(detailData)}); episodes PASS (${episodes.size} targeted rows, ${bucket(episodeData)}); " +
                        "videos PASS ($videoCount rows, ${bucket(videoData)}). No playback or media download."
                }
                host.revoke()
                file.delete()
                results.putString("stream", "Exact authorized AnimeGG 14.2: signature/hash verified; isolated source discovery PASS; $streamSummary Approval revoked.\n")
                finish(Activity.RESULT_OK, results)
                return
            }
            val animeFile = copyFixture("aniyomi-fixture-anime.apk")
            val anime = data(await { host.inspectApk(animeFile.absolutePath, "anime", it) })
            check((anime["certificateSha256"] as String).length == 64)
            check((anime["apkSha256"] as String).length == 64)
            check(host.approve(anime.getValue("inspectionId") as String)["ok"] == true)
            val animeId = anime.getValue("extensionId") as String
            // Simulate a pre-fix cache snapshot, migrate through the real signer/hash
            // verification path, then remove only this fixture's old cached file.
            val durableFile = File(targetContext.noBackupFilesDir, "aniyomi-verified/${anime["apkSha256"]}.apk")
            check(durableFile.isFile)
            val legacyDirectory = File(targetContext.codeCacheDir, "aniyomi-verified").apply { mkdirs() }
            val legacyFile = File(legacyDirectory, durableFile.name)
            durableFile.copyTo(legacyFile, overwrite = true)
            check(legacyFile.setReadOnly() && durableFile.delete())
            check(await { host.request(mapOf("extensionId" to animeId, "operation" to "sources"), it) }["ok"] == true)
            check(durableFile.isFile && legacyFile.delete())
            val reopened = AniyomiNativeHost(targetContext) { enabled }
            try {
                check(await { reopened.request(mapOf("extensionId" to animeId, "operation" to "sources"), it) }["ok"] == true)
            } finally { reopened.close() }
            results.putString("snapshotStorage", "PASS: approved APK migrated from old cache, signer/hash reverified, fresh store survives cache-file removal")
            val sources = data(await { host.request(mapOf("extensionId" to animeId, "operation" to "sources"), it) })
            check((sources["sources"] as List<*>).size == 1)
            val noHttp = mapOf("requestCount" to 0, "requestLimit" to 16, "failureCount" to 0,
                "requestLimitHit" to false, "lastFailure" to "none")
            check(sources["httpDiagnostics"] == noHttp)
            val forgedDiagnostics = AniyomiHttpDiagnostics(AniyomiHttpRequestBudget(16)).attachTo(
                mapOf("httpDiagnostics" to mapOf("requestCount" to 999, "lastFailure" to "generated-test-secret")),
            )
            check(forgedDiagnostics["httpDiagnostics"] == noHttp)
            results.putString("httpDiagnostics", "PASS: host-owned zero HTTP counts injected; forged worker diagnostics replaced by fixed native scalars")
            for (operation in listOf("search", "details", "episodes", "videos")) {
                val response = await { host.request(mapOf("extensionId" to animeId, "sourceId" to "42",
                    "operation" to operation, "url" to "/fixture", "title" to "Fixture",
                    "query" to "isolation:${Process.myUid()}:${sentinel.absolutePath}"), it) }
                check(response["ok"] == true) { "$operation failed: $response" }
            }
            results.putString("anime", "PASS: sources, asset-backed search, details, episodes, format-hint videos; isolated UID, private-file denial, direct-socket denial")
            for ((query, category) in listOf("failure-abi" to "method_missing", "failure-capability" to "unsupported_capability")) {
                val failure = await { host.request(mapOf("extensionId" to animeId, "sourceId" to "42",
                    "operation" to "search", "query" to query), it) }
                check(failure["ok"] == false && failure["stage"] == "source_search" && failure["cause"] == category)
                check(!failure.toString().contains("generated-test-secret"))
            }
            results.putString("safeDiagnostics", "PASS: isolated ABI/capability failures retain fixed stage/cause only; provider exception text omitted")
            val quickJs = await { host.request(mapOf("extensionId" to animeId, "sourceId" to "42",
                "operation" to "search", "query" to "quickjs"), it) }
            check(quickJs["ok"] == true) { "Direct QuickJS isolated fixture failed: $quickJs" }
            results.putString("quickJs", "PASS: host-owned QuickJS 0.9.2 loaded and evaluated direct extension code inside disposable isolated UID")
            val mangaFile = copyFixture("aniyomi-fixture-manga.apk")
            val manga = data(await { host.inspectApk(mangaFile.absolutePath, "manga", it) })
            check(host.approve(manga.getValue("inspectionId") as String)["ok"] == true)
            val mangaId = manga.getValue("extensionId") as String
            val mangaSources = data(await { host.request(mapOf("extensionId" to mangaId, "operation" to "sources"), it) })
            val sourceId = ((mangaSources["sources"] as List<*>).single() as Map<*, *>)["id"] as String
            for (operation in listOf("search", "details", "chapters", "pages")) {
                val response = await { host.request(mapOf("extensionId" to mangaId, "sourceId" to sourceId,
                    "operation" to operation, "url" to "/fixture", "title" to "Fixture"), it) }
                check(response["ok"] == true) { "$operation failed: $response" }
            }
            results.putString("manga", "PASS: sources, search, details, chapters, pages")
            val brokerResponse = await { host.request(mapOf("extensionId" to mangaId, "sourceId" to sourceId,
                "operation" to "search", "query" to "broker"), it) }
            check(brokerResponse["ok"] == true) { "Public example.com broker smoke failed: $brokerResponse" }
            val brokerStats = data(brokerResponse)["httpDiagnostics"] as Map<*, *>
            check((brokerStats["requestCount"] as Number).toInt() in 1..16)
            check(brokerStats["requestLimit"] == 16 && brokerStats["failureCount"] == 0 &&
                brokerStats["requestLimitHit"] == false && brokerStats["lastFailure"] == "none")
            results.putString("httpBroker", "PASS: real public HTTPS request through host broker and ParsedHttpSource")
            val unsigned = copyFixture("aniyomi-fixture-unsigned.apk")
            check(await { host.inspectApk(unsigned.absolutePath, "anime", it) }["ok"] == false)
            results.putString("signature", "PASS: actual signer/hash reported; unsigned APK rejected")
            val cancellation = CountDownLatch(1)
            val cancelledResult = AtomicReference<Map<String, Any?>>()
            host.request(mapOf("extensionId" to animeId, "sourceId" to "42", "operation" to "search", "query" to "hang")) {
                cancelledResult.set(it); cancellation.countDown()
            }
            Thread.sleep(1000)
            host.cancelRequests()
            check(cancellation.await(5, TimeUnit.SECONDS) && cancelledResult.get()["ok"] == false)
            check(host.listApproved().size == 2)
            check(await { host.request(mapOf("extensionId" to animeId, "operation" to "sources"), it) }["ok"] == true)
            results.putString("cancellation", "PASS: hanging worker cancelled; approvals retained; fresh worker succeeds")
            val started = SystemClock.elapsedRealtime()
            val expired = await { host.request(mapOf("extensionId" to animeId, "sourceId" to "42",
                "operation" to "search", "query" to "hang"), it) }
            check(expired["ok"] == false && SystemClock.elapsedRealtime() - started in 28_000L..34_000L)
            check(await { host.request(mapOf("extensionId" to animeId, "operation" to "sources"), it) }["ok"] == true)
            results.putString("deadline", "PASS: noncooperative worker stopped at hard deadline; fresh worker succeeds")
            enabled = false
            check(await { host.request(mapOf("extensionId" to animeId, "operation" to "sources"), it) }["ok"] == false)
            host.revoke()
            check(host.listApproved().isEmpty())
            check(await { host.request(mapOf("extensionId" to animeId, "operation" to "sources"), it) }["ok"] == false)
            enabled = true
            check(await { host.request(mapOf("extensionId" to animeId, "operation" to "sources"), it) }["ok"] == false)
            results.putString("revocation", "PASS: disable revokes all approvals, including after reenabling")
            results.putString("stream", results.keySet().sorted().joinToString("\n") { "$it: ${results.getString(it)}" } +
                "\nAniyomi first-party isolated-process harness: ALL CHECKS PASSED\n")
            finish(Activity.RESULT_OK, results)
        } catch (error: Throwable) {
            val completedChecks = results.keySet().sorted().joinToString("\n") { "$it: ${results.getString(it)}" }
            results.putString("stream", "$completedChecks\nAniyomi fixture FAILED: ${error.javaClass.simpleName}: ${error.message}\n${error.stackTraceToString()}")
            finish(Activity.RESULT_CANCELED, results)
        } finally {
            if (inspectAuthorizedAnimeGG || inspectAuthorizedKickAssAnime ||
                inspectAuthorizedAnikoto || inspectAuthorizedOneTwoThreeAnime) host?.revoke()
            if (inspectAuthorizedAnimeGG) File(targetContext.cacheDir, "authorized-animegg-14.2.apk").delete()
            if (inspectAuthorizedKickAssAnime) File(targetContext.cacheDir, "authorized-kickassanime-14.61.apk").delete()
            if (inspectAuthorizedAnikoto) File(targetContext.cacheDir, "authorized-anikoto-14.6.apk").delete()
            if (inspectAuthorizedAnikotoCurrent) File(targetContext.cacheDir, "authorized-anikoto-16.8.apk").delete()
            if (inspectAuthorizedOneTwoThreeAnime) File(targetContext.cacheDir, "authorized-onetwothreeanime-14.2.apk").delete()
            host?.close()
            sentinel.delete()
        }
    }

    /** Exact opt-in test APKs only; this is not a generic extension loader. */
    private fun inspectAuthorizedProxyFixture(
        host: AniyomiNativeHost,
        label: String,
        filename: String,
        payload: String?,
        expectedBytes: Int,
        expectedHash: String,
        expectedPackage: String,
        expectedSourceName: String,
        expectedSourceId: String,
    ): String {
        val file = File(targetContext.cacheDir, filename)
        try {
            payload?.let { encoded ->
                // Large adb arguments are fed by the caller through shell stdin.
                // The allowance applies only to these size/hash/certificate pins.
                check(encoded.length <= 200_000)
                val bytes = Base64.decode(encoded, Base64.NO_WRAP)
                check(bytes.size == expectedBytes)
                val hash = MessageDigest.getInstance("SHA-256").digest(bytes)
                    .joinToString("") { "%02x".format(it.toInt() and 255) }
                check(hash == expectedHash)
                file.writeBytes(bytes)
            }
            check(file.length() == expectedBytes.toLong())
            val identity = data(await { host.inspectApk(file.absolutePath, "anime", it) })
            check(identity["apkSha256"] == expectedHash)
            check(identity["certificateSha256"] == "cbec121aa82ebb02aaa73806992e0368a97d47b5451ed6524816d03084c45905")
            check(identity["packageName"] == expectedPackage)
            check(host.approve(identity.getValue("inspectionId") as String)["ok"] == true)
            val extensionId = identity.getValue("extensionId")
            val listed = data(await { host.request(mapOf("extensionId" to extensionId, "operation" to "sources"), it) })
            val source = (listed["sources"] as List<*>).single() as Map<*, *>
            check(source["name"] == expectedSourceName && source["id"] == expectedSourceId)
            val search = data(await { host.request(mapOf("extensionId" to extensionId,
                "sourceId" to source["id"], "operation" to "search", "query" to "One Piece", "page" to 1), it) })
            val matches = search["items"] as List<*>
            val selected = matches.filterIsInstance<Map<*, *>>().firstOrNull {
                (it["title"] as? String)?.equals("One Piece", ignoreCase = true) == true
            } ?: error("Authorized $label exact One Piece title missing (${matches.size} search rows)")
            val detail = data(await { host.request(mapOf("extensionId" to extensionId,
                "sourceId" to source["id"], "operation" to "details", "url" to selected["url"],
                "title" to selected["title"]), it) })["item"] as Map<*, *>
            check((detail["title"] as? String)?.equals("One Piece", ignoreCase = true) == true) {
                "Authorized $label details title mismatch"
            }
            val episodeData = data(await { host.request(mapOf("extensionId" to extensionId,
                "sourceId" to source["id"], "operation" to "episodes", "url" to detail["url"],
                "title" to detail["title"], "targetEpisode" to 1), it) })
            val episodes = episodeData["chapters"] as List<*>
            val episode = episodes.filterIsInstance<Map<*, *>>().firstOrNull {
                (it["number"] as? Number)?.toDouble() == 1.0
            } ?: error("Authorized $label exact episode 1 missing (${episodes.size} targeted rows)")
            val videoResponse = await { host.request(mapOf("extensionId" to extensionId,
                "sourceId" to source["id"], "operation" to "videos", "url" to episode["url"],
                "title" to episode["name"], "resolveLazyHosters" to true), it) }
            check(videoResponse["ok"] == true) {
                "Authorized $label videos failed after ${matches.size} search rows, details and ${episodes.size} targeted episodes: $videoResponse"
            }
            val videoData = data(videoResponse)
            val videos = videoData["videos"] as List<*>
            val videoCounts = listOf("originalCount", "discardedVideoCount", "returnedCount", "localHlsBridgeCount")
                .joinToString(", ") { key -> "$key=${(videoData[key] as? Number)?.toLong() ?: -1L}" }
            check(videos.isNotEmpty()) { "Authorized $label returned no playable videos after ${matches.size} search rows and ${episodes.size} targeted episodes ($videoCounts; -1 means absent)" }
            check(videos.filterIsInstance<Map<*, *>>().all { (it["url"] as? String)?.startsWith("https://") == true })
            return "Exact authorized $label: signature/hash/source verified; isolated search PASS (${matches.size} rows), " +
                "exact One Piece details PASS, episode 1 PASS (${episodes.size} targeted rows), videos PASS (${videos.size} HTTPS rows). " +
                "No playback or media download. Approval revoked."
        } finally {
            host.revoke()
            file.delete()
        }
    }

    private fun checkPhoneSetupCrypto() {
        fun invoke(method: String, arguments: Map<String, Any?>? = null): Any? {
            var returned: Any? = null
            var completed = false
            val handled = PhoneSetupP256Bridge.handle(MethodCall(method, arguments), object : MethodChannel.Result {
                override fun success(result: Any?) { returned = result; completed = true }
                override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) { error("Native P-256 bridge rejected a generated test input") }
                override fun notImplemented() { error("Native P-256 bridge method missing") }
            })
            check(handled && completed)
            return returned
        }
        val first = invoke("generatePhoneSetupP256KeyPair") as Map<*, *>
        val second = invoke("generatePhoneSetupP256KeyPair") as Map<*, *>
        val buffers = (first.values + second.values).map { it as ByteArray }.toMutableList()
        try {
            check(buffers.size == 6 && buffers.all { it.size == 32 })
            fun derive(local: Map<*, *>, remote: Map<*, *>) = invoke("derivePhoneSetupP256SharedSecret", mapOf(
                "privateD" to local["d"], "localX" to local["x"], "localY" to local["y"],
                "remoteX" to remote["x"], "remoteY" to remote["y"],
            )) as ByteArray
            val left = derive(first, second).also { buffers.add(it) }
            val right = derive(second, first).also { buffers.add(it) }
            check(left.size == 32 && left.contentEquals(right))
        } finally { buffers.forEach { it.fill(0) } }
    }

    private fun copyFixture(name: String): File = File(targetContext.cacheDir, name).also { output ->
        context.assets.open(name).use { input -> output.outputStream().use(input::copyTo) }
    }
    private fun await(action: ((Map<String, Any?>) -> Unit) -> Unit): Map<String, Any?> {
        val latch = CountDownLatch(1)
        val result = AtomicReference<Map<String, Any?>>()
        action { result.set(it); latch.countDown() }
        check(latch.await(35, TimeUnit.SECONDS)) { "Native callback did not finish" }
        return result.get()
    }
    @Suppress("UNCHECKED_CAST")
    private fun data(result: Map<String, Any?>): Map<String, Any?> {
        check(result["ok"] == true) { "Native operation failed: $result" }
        return result["data"] as Map<String, Any?>
    }
}
