package dev.animetv.anime_tv

import java.io.File
import java.lang.reflect.Modifier
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DiscordRichPresenceBridgeAbiTest {
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
}
