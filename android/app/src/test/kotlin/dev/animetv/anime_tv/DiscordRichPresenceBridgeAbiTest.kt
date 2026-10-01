package dev.animetv.anime_tv

import java.io.File
import java.lang.reflect.Modifier
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DiscordRichPresenceBridgeAbiTest {
    @Test
    fun `reading artwork extends its JNI signature without changing playback`() {
        val bridge = Class.forName(
            "dev.animetv.anime_tv.DiscordRichPresenceBridge", false, javaClass.classLoader,
        )
        val reading = bridge.getDeclaredMethod(
            "nativeUpdateReadingPresence", String::class.java, String::class.java,
            Int::class.javaPrimitiveType, Int::class.javaPrimitiveType, String::class.java,
        )
        val playback = bridge.getDeclaredMethod(
            "nativeUpdatePlaybackPresence", String::class.java, Int::class.javaPrimitiveType,
            Boolean::class.javaPrimitiveType, Long::class.javaPrimitiveType,
            Long::class.javaPrimitiveType, String::class.java,
        )
        for (method in listOf(reading, playback)) {
            assertTrue("${method.name} must remain native", Modifier.isNative(method.modifiers))
            assertEquals("${method.name} must return void", Void.TYPE, method.returnType)
        }
    }

    @Test
    fun `native callbacks retain the void static JNI contract`() {
        val bridge = Class.forName(
            "dev.animetv.anime_tv.DiscordRichPresenceBridge",
            false,
            javaClass.classLoader,
        )
        val callbacks = listOf(
            bridge.getDeclaredMethod(
                "onAuthResult",
                Boolean::class.javaPrimitiveType,
                String::class.java,
                String::class.java,
                Int::class.javaPrimitiveType,
                Int::class.javaPrimitiveType,
                String::class.java,
                String::class.java,
            ),
            bridge.getDeclaredMethod(
                "onRefreshResult",
                Long::class.javaPrimitiveType,
                Boolean::class.javaPrimitiveType,
                String::class.java,
                String::class.java,
                Int::class.javaPrimitiveType,
                Int::class.javaPrimitiveType,
                String::class.java,
                String::class.java,
            ),
            bridge.getDeclaredMethod(
                "onConnectionState",
                String::class.java,
                String::class.java,
            ),
            bridge.getDeclaredMethod(
                "onPresenceResult",
                Boolean::class.javaPrimitiveType,
                String::class.java,
            ),
            bridge.getDeclaredMethod(
                "onRevokeResult",
                Boolean::class.javaPrimitiveType,
                String::class.java,
            ),
            bridge.getDeclaredMethod("onTokenExpiring"),
        )

        callbacks.forEach { callback ->
            assertTrue("${callback.name} must remain static for JNI", Modifier.isStatic(callback.modifiers))
            assertEquals("${callback.name} must return void for JNI", Void.TYPE, callback.returnType)
        }
        val refresh = bridge.getDeclaredMethod(
            "nativeRefreshToken", String::class.java, Long::class.javaPrimitiveType,
        )
        assertTrue("refresh request identity must cross JNI", Modifier.isNative(refresh.modifiers))
        assertEquals(Void.TYPE, refresh.returnType)
    }

    @Test
    fun `disconnect clears pending connect before native cancellation and retry can claim it`() {
        val relativeSource =
            "src/main/kotlin/dev/animetv/anime_tv/DiscordRichPresenceBridge.kt"
        val workingDirectory = System.getProperty("user.dir") ?: "."
        val sourceFile = generateSequence(File(workingDirectory)) { it.parentFile }
            .take(6)
            .flatMap { directory ->
                sequenceOf(
                    File(directory, relativeSource),
                    File(directory, "app/$relativeSource"),
                    File(directory, "android/app/$relativeSource"),
                )
            }
            .firstOrNull(File::isFile)
        assertTrue("Discord bridge source must be available to the contract test", sourceFile != null)
        val source = sourceFile!!.readText()

        val connectBranch = source
            .substringAfter("\"discordConnect\" -> {", "")
            .substringBefore("\"discordRevoke\" -> {")
        assertTrue(
            "discordConnect must atomically claim the pending-operation slot",
            connectBranch.contains("pendingConnect.trySet(result)"),
        )

        val disconnectBranch = source
            .substringAfter("\"discordDisconnect\" -> {", "")
            .substringBefore("else -> false")
        val clearIndex = disconnectBranch.indexOf("pendingConnect.take()")
        val nativeCancelIndex = disconnectBranch.indexOf("nativeDisconnect()")
        assertTrue(
            "discordDisconnect must release pendingConnect before native cancellation",
            clearIndex >= 0 && nativeCancelIndex > clearIndex,
        )
        assertTrue(
            "every native connection needs a bounded handler deadline",
            connectBranch.contains("mainHandler.postDelayed(timeout, CONNECTION_TIMEOUT_MS)") &&
                source.contains("CONNECTION_TIMEOUT_MS = 20_000L"),
        )
        val timeoutBranch = connectBranch.substringAfter("val timeout = Runnable {", "")
            .substringBefore("connectionTimeout = timeout")
        assertTrue(
            "timeout must atomically clear only its own pending result before cancellation",
            timeoutBranch.indexOf("pendingConnect.takeIf(result)") in
                0 until timeoutBranch.indexOf("nativeDisconnect()"),
        )
        assertTrue(
            "queued native statuses must not settle a newer connect generation",
            source.contains("if (generation != connectionGeneration) return@post"),
        )
        val refreshBranch = source.substringAfter("\"discordRefreshToken\" -> {", "")
            .substringBefore("\"discordCancelRefreshToken\" -> {")
        assertTrue(
            "refresh needs an identity-owned watchdog and request identity sent into native",
            refreshBranch.contains("pendingRefresh.takeIf(operation)") &&
                refreshBranch.contains("mainHandler.postDelayed(timeout, REFRESH_TIMEOUT_MS)") &&
                refreshBranch.contains("nativeRefreshToken(refreshToken, operation.requestId)"),
        )
        assertTrue(
            "late refresh callbacks must match their original request identity",
            source.contains("pendingRefresh.takeMatching { it.requestId == requestId }"),
        )
        val cancelRefreshBranch = source.substringAfter("\"discordCancelRefreshToken\" -> {", "")
            .substringBefore("\"discordConnect\" -> {")
        assertTrue("refresh cancellation must release its pending slot", cancelRefreshBranch.contains("pendingRefresh.take()"))
        assertTrue("refresh cancellation must not disconnect or revoke", !cancelRefreshBranch.contains("nativeDisconnect()") && !cancelRefreshBranch.contains("nativeRevoke("))
    }

    @Test
    fun `TV authentication is rejected before native browser authorization`() {
        val relativeSource =
            "src/main/kotlin/dev/animetv/anime_tv/DiscordRichPresenceBridge.kt"
        val workingDirectory = System.getProperty("user.dir") ?: "."
        val sourceFile = generateSequence(File(workingDirectory)) { it.parentFile }
            .take(6)
            .flatMap { directory ->
                sequenceOf(
                    File(directory, relativeSource),
                    File(directory, "app/$relativeSource"),
                    File(directory, "android/app/$relativeSource"),
                )
            }
            .firstOrNull(File::isFile)
        assertTrue("Discord bridge source must be available to the contract test", sourceFile != null)
        val branch = sourceFile!!.readText()
            .substringAfter("\"discordAuthenticate\" -> {", "")
            .substringBefore("\"discordCancelAuthentication\" -> {")
        val guardIndex = branch.indexOf("if (!allowsMobileOAuth)")
        val nativeIndex = branch.indexOf("nativeAuthenticate(useDeviceAuthFlow)")
        assertTrue(
            "TV guard must run before the browser-opening native authorization call",
            guardIndex >= 0 && nativeIndex > guardIndex,
        )
    }

    @Test
    fun `native bridge serializes presence writes and invalidates stale connects`() {
        val relativeSource = "src/main/cpp/discord_rich_presence.cpp"
        val workingDirectory = System.getProperty("user.dir") ?: "."
        val sourceFile = generateSequence(File(workingDirectory)) { it.parentFile }
            .take(6)
            .flatMap { directory ->
                sequenceOf(
                    File(directory, relativeSource),
                    File(directory, "app/$relativeSource"),
                    File(directory, "android/app/$relativeSource"),
                )
            }
            .firstOrNull(File::isFile)
        assertTrue("Discord native source must be available to the contract test", sourceFile != null)
        val source = sourceFile!!.readText()

        assertTrue(
            "presence updates must be held while an earlier SDK write is in flight",
            source.contains("g_presence_update_in_flight") &&
                source.contains("!g_pending_presence.has_value()"),
        )
        assertTrue(
            "connect callbacks must be invalidated when a newer connect or disconnect wins",
            source.contains("g_connection_generation") &&
                source.contains("connection_generation != g_connection_generation.load()"),
        )
        assertTrue(
            "queued status must match the current SDK state and current installed token",
            source.contains("status != g_client->GetStatus()") &&
                source.contains("g_installed_token_connection_generation.load() != connection_generation") &&
                source.contains("g_installed_token_connection_generation.store(connection_generation)"),
        )
        val readyGuard = source.substringAfter("if (status == discordpp::Client::Status::Ready &&", "")
            .substringBefore("const bool ready =")
        assertTrue(
            "Ready must not depend on the one-shot manual-connect marker consumed before Connect",
            !readyGuard.contains("g_token_ready_connection_generation"),
        )
        val nativeConnect = source.substringAfter("DiscordRichPresenceBridge_nativeConnect(", "")
            .substringBefore("DiscordRichPresenceBridge_nativeRevoke(")
        val readyFallback = nativeConnect.substringAfter("if (status == discordpp::Client::Status::Ready)", "")
        assertTrue(
            "successful token update on an already-ready client must unblock presence publishing",
            readyFallback.indexOf("g_ready.store(true)") in
                0 until readyFallback.indexOf("flush_pending_presence()"),
        )
        assertTrue(
            "refresh callback ABI must carry the request ID captured by its SDK callback",
            source.contains("(JZLjava/lang/String;Ljava/lang/String;IILjava/lang/String;Ljava/lang/String;)V") &&
                source.contains("post([refresh_token, request_id]") &&
                source.contains("[request_id](discordpp::ClientResult result"),
        )
        assertTrue(
            "UpdateToken must only open a websocket from the fully disconnected state",
            source.contains("status == discordpp::Client::Status::Disconnected"),
        )
        assertTrue(
            "a retry during teardown must wait for its token before connecting",
            source.contains("initial_status == discordpp::Client::Status::Disconnecting") &&
                source.contains("g_token_ready_connection_generation !=") &&
                source.contains("connect_pending_if_disconnected()"),
        )
        val queuedConnect = source.substringAfter("bool connect_pending_if_disconnected()", "")
            .substringBefore("bool same_presence_timeline", "")
        assertTrue(
            "the queued connect must be consumed before opening the websocket",
            queuedConnect.indexOf("g_manual_connect_after_token_update = false") in
                0 until queuedConnect.indexOf("g_client->Connect()"),
        )
    }
}
