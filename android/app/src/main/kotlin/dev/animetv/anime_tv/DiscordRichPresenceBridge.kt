package dev.animetv.anime_tv

import android.app.Activity
import android.os.Handler
import android.os.Looper
import androidx.annotation.Keep
import androidx.browser.customtabs.CustomTabsClient
import com.discord.socialsdk.DiscordSocialSdkInit
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.URI

/**
 * Small, token-safe adapter around Discord's native Social SDK.
 *
 * OAuth tokens cross the Flutter method channel only long enough to be stored
 * by flutter_secure_storage. They are never logged, placed in intents, or
 * included in playback diagnostics.
 */
@Keep
object DiscordRichPresenceBridge {
    private const val APPLICATION_ID = 1536801401710055474L
    private val mainHandler = Handler(Looper.getMainLooper())
    private val operationLock = Any()

    private var channel: MethodChannel? = null
    private var nativeLoaded = false
    private var initialized = false
    private var useDeviceAuthFlow = false
    private var allowsMobileOAuth = true
    private var canLaunchAuthorization = false
    private var connectionState = "disconnected"
    private var pendingAuth: MethodChannel.Result? = null
    private var pendingRefresh: MethodChannel.Result? = null
    private val pendingConnect = PendingOperationSlot<MethodChannel.Result>()
    private var pendingRevoke: MethodChannel.Result? = null

    fun attach(activity: Activity, channel: MethodChannel) {
        this.channel = channel
        allowsMobileOAuth = DiscordAuthFlowPolicy.allowsMobileOAuth(
            TelevisionDevicePolicy.isTelevision(activity),
        )
        useDeviceAuthFlow = DiscordAuthFlowPolicy.shouldUseDeviceFlow(
            uiMode = activity.resources.configuration.uiMode,
            hasLeanback = activity.packageManager.hasSystemFeature("android.software.leanback"),
        )
        canLaunchAuthorization = CustomTabsClient.getPackageName(activity, null) != null
        // This loads the official SDK library before our JNI bridge, then gives
        // Discord the Activity it needs for its TV/device authorization UI.
        DiscordSocialSdkInit.setEngineActivity(activity)
        synchronized(operationLock) {
            if (!nativeLoaded) {
                System.loadLibrary("tetotv_discord")
                nativeLoaded = true
            }
            if (!initialized) {
                nativeInitialize()
                initialized = true
            }
        }
    }

    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        return when (call.method) {
            "discordSdkInfo" -> {
                result.success(
                    mapOf(
                        "available" to initialized,
                        "applicationId" to APPLICATION_ID.toString(),
                        "version" to if (initialized) nativeSdkVersion() else "unavailable",
                        "status" to connectionState,
                    ),
                )
                true
            }
            "discordAuthenticate" -> {
                if (!allowsMobileOAuth) {
                    result.error(
                        "DISCORD_DEVICE_AUTH_REQUIRED",
                        "Discord linking on TV uses TetoTV's QR code screen.",
                        null,
                    )
                } else if (!canLaunchAuthorization) {
                    result.error(
                        "DISCORD_AUTH_UNAVAILABLE",
                        "Discord linking requires a secure web browser on this device.",
                        null,
                    )
                } else {
                    synchronized(operationLock) {
                        if (pendingAuth != null) {
                            result.error("DISCORD_AUTH_BUSY", "Discord account linking is already open.", null)
                        } else {
                            pendingAuth = result
                            nativeAuthenticate(useDeviceAuthFlow)
                        }
                    }
                }
                true
            }
            "discordCancelAuthentication" -> {
                val pending = synchronized(operationLock) {
                    pendingAuth.also { pendingAuth = null }
                }
                nativeCancelAuthentication(useDeviceAuthFlow)
                pending?.error(
                    "DISCORD_AUTH_CANCELED",
                    "Discord account linking was canceled.",
                    null,
                )
                result.success(null)
                true
            }
            "discordRefreshToken" -> {
                val refreshToken = call.argument<String>("refreshToken").orEmpty()
                if (refreshToken.isBlank()) {
                    result.error("DISCORD_REFRESH_TOKEN", "Discord needs to be linked again.", null)
                } else {
                    synchronized(operationLock) {
                        if (pendingRefresh != null) {
                            result.error("DISCORD_REFRESH_BUSY", "Discord is already refreshing.", null)
                        } else {
                            pendingRefresh = result
                            nativeRefreshToken(refreshToken)
                        }
                    }
                }
                true
            }
            "discordConnect" -> {
                val accessToken = call.argument<String>("accessToken").orEmpty()
                val tokenType = call.argument<Int>("tokenType") ?: 0
                if (accessToken.isBlank()) {
                    result.error("DISCORD_ACCESS_TOKEN", "Discord needs to be linked again.", null)
                } else {
                    if (!pendingConnect.trySet(result)) {
                        result.error("DISCORD_CONNECT_BUSY", "Discord is already connecting.", null)
                    } else {
                        connectionState = "connecting"
                        nativeConnect(accessToken, tokenType)
                    }
                }
                true
            }
            "discordRevoke" -> {
                val token = call.argument<String>("token").orEmpty()
                if (token.isBlank()) {
                    nativeDisconnect()
                    result.success(true)
                } else {
                    synchronized(operationLock) {
                        if (pendingRevoke != null) {
                            result.error("DISCORD_REVOKE_BUSY", "Discord is already disconnecting.", null)
                        } else {
                            pendingRevoke = result
                            nativeRevoke(token)
                        }
                    }
                }
                true
            }
            "discordUpdatePresence" -> {
                val title = call.argument<String>("title").orEmpty().trim().take(120)
                if (title.isNotEmpty()) {
                    nativeUpdatePresence(
                        title,
                        (call.argument<Number>("episode")?.toInt() ?: 0).coerceAtLeast(0),
                        call.argument<Boolean>("playing") ?: false,
                        (call.argument<Number>("positionMs")?.toLong() ?: 0L).coerceAtLeast(0L),
                        (call.argument<Number>("durationMs")?.toLong() ?: 0L).coerceAtLeast(0L),
                        sanitizeDiscordArtworkUrl(call.argument<String>("artworkUrl")),
                    )
                }
                result.success(null)
                true
            }
            "discordClearPresence" -> {
                nativeClearPresence()
                result.success(null)
                true
            }
            "discordDisconnect" -> {
                // Atomically clear the method-channel operation before asking
                // native Discord to disconnect. A subsequent Retry can claim
                // a fresh slot instead of receiving DISCORD_CONNECT_BUSY.
                val canceledConnect = pendingConnect.take()
                nativeDisconnect()
                connectionState = "disconnected"
                canceledConnect?.error(
                    "DISCORD_CONNECT_CANCELED",
                    "Discord connection attempt was canceled.",
                    null,
                )
                result.success(null)
                true
            }
            else -> false
        }
    }

    fun updatePlayback(data: Map<String, Any?>) {
        updatePlayback(
            title = (data["title"] as? String).orEmpty(),
            episode = (data["episode"] as? Number)?.toInt()
                ?: (data["subtitle"] as? String)
                    ?.substringAfter("Episode ", "0")
                    ?.toIntOrNull()
                ?: 0,
            playing = data["playing"] as? Boolean ?: false,
            positionMs = (data["positionMs"] as? Number)?.toLong() ?: 0L,
            durationMs = (data["durationMs"] as? Number)?.toLong() ?: 0L,
            artworkUrl = data["artworkUrl"] as? String,
        )
    }

    fun updatePlayback(
        title: String,
        episode: Int,
        playing: Boolean,
        positionMs: Long,
        durationMs: Long,
        artworkUrl: String? = null,
    ) {
        if (!initialized || connectionState != "ready") return
        val safeTitle = title.trim().take(120)
        if (safeTitle.isEmpty()) return
        nativeUpdatePresence(
            safeTitle,
            episode.coerceAtLeast(0),
            playing,
            positionMs.coerceAtLeast(0L),
            durationMs.coerceAtLeast(0L),
            sanitizeDiscordArtworkUrl(artworkUrl),
        )
    }

    fun clearPlayback() {
        if (initialized && connectionState == "ready") nativeClearPresence()
    }

    @JvmStatic
    fun onAuthResult(
        success: Boolean,
        accessToken: String,
        refreshToken: String,
        tokenType: Int,
        expiresIn: Int,
        scopes: String,
        error: String,
    ) {
        mainHandler.post {
            val pending = synchronized(operationLock) {
                pendingAuth.also { pendingAuth = null }
            }
            if (success) {
                pending?.success(tokenPayload(accessToken, refreshToken, tokenType, expiresIn, scopes))
            } else {
                pending?.error("DISCORD_AUTH_FAILED", friendly(error), null)
            }
        }
    }

    @JvmStatic
    fun onRefreshResult(
        success: Boolean,
        accessToken: String,
        refreshToken: String,
        tokenType: Int,
        expiresIn: Int,
        scopes: String,
        error: String,
    ) {
        mainHandler.post {
            val pending = synchronized(operationLock) {
                pendingRefresh.also { pendingRefresh = null }
            }
            if (success) {
                pending?.success(tokenPayload(accessToken, refreshToken, tokenType, expiresIn, scopes))
            } else {
                pending?.error("DISCORD_REFRESH_FAILED", friendly(error), null)
            }
        }
    }

    @JvmStatic
    fun onConnectionState(status: String, error: String) {
        mainHandler.post {
            connectionState = status
            channel?.invokeMethod(
                "discordConnectionState",
                mapOf("status" to status, "error" to friendly(error, allowEmpty = true)),
            )
            val pending = when (status) {
                "ready", "error", "disconnected" -> pendingConnect.take()
                else -> null
            }
            when (status) {
                "ready" -> pending?.success(mapOf("status" to "ready"))
                "error" -> pending?.error("DISCORD_CONNECT_FAILED", friendly(error), null)
                "disconnected" -> if (pending != null) {
                    pending.error(
                        "DISCORD_CONNECT_FAILED",
                        friendly(error.ifBlank { "Discord disconnected before it was ready." }),
                        null,
                    )
                }
            }
        }
    }

    @JvmStatic
    fun onPresenceResult(success: Boolean, error: String) {
        mainHandler.post {
            if (!success) {
                channel?.invokeMethod(
                    "discordPresenceError",
                    mapOf("error" to friendly(error)),
                )
            }
        }
    }

    @JvmStatic
    fun onRevokeResult(success: Boolean, error: String) {
        mainHandler.post {
            nativeDisconnect()
            connectionState = "disconnected"
            val pending = synchronized(operationLock) {
                pendingRevoke.also { pendingRevoke = null }
            }
            if (success) {
                pending?.success(true)
            } else {
                // Local unlinking must remain possible while Discord is offline.
                pending?.success(false)
                channel?.invokeMethod(
                    "discordPresenceError",
                    mapOf("error" to friendly(error)),
                )
            }
        }
    }

    @JvmStatic
    fun onTokenExpiring() {
        mainHandler.post {
            channel?.invokeMethod("discordTokenExpiring", null)
        }
    }

    private fun tokenPayload(
        accessToken: String,
        refreshToken: String,
        tokenType: Int,
        expiresIn: Int,
        scopes: String,
    ): Map<String, Any> = mapOf(
        "accessToken" to accessToken,
        "refreshToken" to refreshToken,
        "tokenType" to tokenType,
        "expiresAtMs" to System.currentTimeMillis() + expiresIn.coerceAtLeast(0) * 1_000L,
        "scopes" to scopes,
    )

    private fun friendly(error: String, allowEmpty: Boolean = false): String {
        val cleaned = error.replace(Regex("[\\r\\n\\t]+"), " ").trim().take(240)
        if (cleaned.isNotEmpty() || allowEmpty) return cleaned
        return "Discord could not complete the request. Please try again."
    }

    private external fun nativeInitialize()
    private external fun nativeSdkVersion(): String
    private external fun nativeAuthenticate(useDeviceFlow: Boolean)
    private external fun nativeCancelAuthentication(useDeviceFlow: Boolean)
    private external fun nativeRefreshToken(refreshToken: String)
    private external fun nativeConnect(accessToken: String, tokenType: Int)
    private external fun nativeRevoke(token: String)
    private external fun nativeUpdatePresence(
        title: String,
        episode: Int,
        playing: Boolean,
        positionMs: Long,
        durationMs: Long,
        artworkUrl: String,
    )
    private external fun nativeClearPresence()
    private external fun nativeDisconnect()
}

/** Accept only bounded public HTTPS artwork references for Discord to fetch. */
internal fun sanitizeDiscordArtworkUrl(value: String?): String {
    val candidate = value?.trim().orEmpty()
    // Discord's ActivityAssets contract accepts at most 300 characters.
    if (candidate.isEmpty() || candidate.length > 300) return ""
    return runCatching {
        val uri = URI(candidate)
        if (
            !uri.scheme.equals("https", ignoreCase = true) ||
            uri.host.isNullOrBlank() ||
            uri.rawUserInfo != null ||
            uri.fragment != null
        ) {
            ""
        } else {
            candidate
        }
    }.getOrDefault("")
}
