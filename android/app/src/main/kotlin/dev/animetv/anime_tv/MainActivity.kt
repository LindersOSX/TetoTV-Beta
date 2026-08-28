package dev.animetv.anime_tv

import android.annotation.SuppressLint
import android.content.ContentUris
import android.app.AlarmManager
import android.app.ActivityManager
import android.app.PendingIntent
import android.content.Context
import android.content.ContentResolver
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.PackageInfo
import android.content.pm.FeatureInfo
import android.hardware.display.DisplayManager
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.provider.OpenableColumns
import android.provider.Settings
import android.speech.RecognizerIntent
import android.speech.RecognitionListener
import android.speech.SpeechRecognizer
import androidx.core.content.edit
import androidx.core.content.FileProvider
import androidx.core.net.toUri
import androidx.tvprovider.media.tv.TvContractCompat
import androidx.tvprovider.media.tv.WatchNextProgram
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import dev.animetv.anime_tv.security.AppDeepLinkPolicy
import java.io.File
import java.security.MessageDigest
import java.util.zip.ZipFile
import kotlin.math.abs

class MainActivity : FlutterActivity() {
    private val channelName = "dev.tetotv/android_tv"
    private lateinit var channel: MethodChannel
    private lateinit var mediaSession: MediaSessionCompat
    private var pendingApkInstallResult: MethodChannel.Result? = null
    private var pendingApkPath: String? = null
    private var pendingVoiceSearchResult: MethodChannel.Result? = null
    private var pendingLocalMediaResult: MethodChannel.Result? = null
    private var pendingTrailerResult: MethodChannel.Result? = null
    private var externalProxyHandoffActive = false
    private var externalProxyHandoffBackgrounded = false
    private var speechRecognizer: SpeechRecognizer? = null
    private val voiceSearchHandler = Handler(Looper.getMainLooper())
    private val voiceSearchTimeout = Runnable {
        if (pendingVoiceSearchResult != null) {
            finishEmbeddedVoiceSearch(
                value = null,
                errorMessage = "Voice search timed out. Please try again.",
            )
        }
    }
    private var mediaSeekBackIncrementMs = DEFAULT_SEEK_INCREMENT_MS
    private var mediaSeekForwardIncrementMs = DEFAULT_SEEK_INCREMENT_MS

    override fun onCreate(savedInstanceState: Bundle?) {
        sanitizeIncomingAppLink(intent)
        super.onCreate(savedInstanceState)
    }

    override fun getInitialRoute(): String? =
        AppDeepLinkPolicy.initialRouteForExportedActivity()

    override fun onNewIntent(intent: Intent) {
        sanitizeIncomingAppLink(intent)
        super.onNewIntent(intent)
    }

    /**
     * MainActivity must be exported for TV launchers. Do not let that exported
     * surface pass arbitrary URI routes to Dart, where malformed numeric route
     * parameters could otherwise terminate the app. Manifest filters do not
     * protect against explicit intents sent by another installed application.
     */
    private fun sanitizeIncomingAppLink(incoming: Intent) {
        if (incoming.data == null) return
        if (
            incoming.action == Intent.ACTION_VIEW &&
            AppDeepLinkPolicy.isAllowed(incoming.dataString)
        ) return
        incoming.action = Intent.ACTION_MAIN
        incoming.data = null
        incoming.removeCategory(Intent.CATEGORY_BROWSABLE)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        DiscordRichPresenceBridge.attach(this, channel)
        createMediaSession()
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "isTelevision" -> result.success(isTelevision())
                    "getDeviceProfile" -> result.success(deviceProfile())
                    "getAppVersion" -> result.success(appVersion())
                    "inspectApk" -> result.success(inspectApk(call.argument<String>("path")))
                    "installApk" -> installApk(call.argument<String>("path"), result)
                    "voiceSearch" -> startVoiceSearch(result)
                    "pickLocalVideo" -> pickLocalVideo(result)
                    "playInAppTrailer" -> playInAppTrailer(
                        provider = call.argument<String>("provider"),
                        videoId = call.argument<String>("videoId"),
                        title = call.argument<String>("title"),
                        result = result,
                    )
                    "openExternalPlayer" -> openExternalPlayer(
                        uriValue = call.argument<String>("uri"),
                        localPath = call.argument<String>("localPath"),
                        mimeType = call.argument<String>("mimeType"),
                        packageName = call.argument<String>("packageName"),
                        result = result,
                    )
                    "openExternalWebPage" -> openExternalWebPage(
                        uriValue = call.argument<String>("uri"),
                        result = result,
                    )
                    "listExternalPlayers" -> result.success(listExternalPlayers())
                    "acquireOfflineDownloadKeepAlive" -> result.success(
                        OfflineDownloadForegroundService.acquire(
                            applicationContext,
                            call.argument<String>("leaseId"),
                        ),
                    )
                    "releaseOfflineDownloadKeepAlive" -> {
                        OfflineDownloadForegroundService.release(
                            applicationContext,
                            call.argument<String>("leaseId"),
                        )
                        result.success(null)
                    }
                    "clearAppCache" -> clearAppCacheAsync(result)
                    "setAnonymousCrashReportingEnabled" -> {
                        AnonymousCrashStore.setEnabled(
                            this,
                            call.argument<Boolean>("enabled") ?: false,
                        )
                        result.success(null)
                    }
                    "storePendingAnonymousCrashReport" -> {
                        @Suppress("UNCHECKED_CAST")
                        val report = call.arguments as? Map<String, Any?> ?: emptyMap()
                        result.success(AnonymousCrashStore.store(this, report))
                    }
                    "getPendingAnonymousCrashReport" ->
                        result.success(AnonymousCrashStore.pending(this))
                    "getRecentLocalCrashSummaries" ->
                        result.success(AnonymousCrashStore.recentLocalCrashSummaries(this))
                    "acknowledgeAnonymousCrashReport" -> {
                        AnonymousCrashStore.acknowledge(
                            this,
                            call.argument<String>("reportId").orEmpty(),
                        )
                        result.success(null)
                    }
                    "clearPendingAnonymousCrashReports" -> {
                        AnonymousCrashStore.clear(this)
                        result.success(null)
                    }
                    "resetApplicationData" -> {
                        val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                        result.success(activityManager.clearApplicationUserData())
                    }
                    "setPreferredFrameRate" -> {
                        val fps = call.argument<Double>("fps") ?: 0.0
                        result.success(setPreferredFrameRate(fps))
                    }
                    "updateMediaSession" -> {
                        @Suppress("UNCHECKED_CAST")
                        val data = call.arguments as? Map<String, Any?> ?: emptyMap()
                        updateMediaSession(data)
                        DiscordRichPresenceBridge.updatePlayback(data)
                        result.success(null)
                    }
                    "clearMediaSession" -> {
                        clearMediaSession()
                        DiscordRichPresenceBridge.clearPlayback()
                        result.success(null)
                    }
                    "publishWatchNext" -> {
                        @Suppress("UNCHECKED_CAST")
                        result.success(publishWatchNext(call.arguments as? Map<String, Any?> ?: emptyMap()))
                    }
                    "removeWatchNext" -> {
                        @Suppress("UNCHECKED_CAST")
                        result.success(removeWatchNext(call.arguments as? Map<String, Any?> ?: emptyMap()))
                    }
                    "scheduleReminder" -> {
                        @Suppress("UNCHECKED_CAST")
                        result.success(scheduleReminder(call.arguments as? Map<String, Any?> ?: emptyMap()))
                    }
                    "syncEpisodeReleaseNotifications" -> {
                        @Suppress("UNCHECKED_CAST")
                        result.success(
                            syncEpisodeReleaseNotifications(
                                call.arguments as? Map<String, Any?> ?: emptyMap(),
                            ),
                        )
                    }
                    "clearPreferredFrameRate" -> {
                        window.attributes = window.attributes.apply { preferredDisplayModeId = 0 }
                        result.success(null)
                    }
                    else -> {
                        if (
                            !PhoneSetupP256Bridge.handle(call, result) &&
                            !DirectTorrentBridge.handle(this, call, result) &&
                            !DiscordRichPresenceBridge.handle(call, result)
                        ) {
                            result.notImplemented()
                        }
                    }
                }
            } catch (error: Throwable) {
                result.error("ANDROID_TV_BRIDGE", error.message, null)
            }
        }
    }

    private fun isTelevision(): Boolean = TelevisionDevicePolicy.isTelevision(this)

    /**
     * Lets Android's Storage Access Framework expose only the video selected
     * by the viewer. This covers internal storage and transient USB document
     * providers without broad storage permissions or raw filesystem paths.
     */
    private fun pickLocalVideo(result: MethodChannel.Result) {
        if (pendingLocalMediaResult != null) {
            result.error(
                "LOCAL_MEDIA_PICKER_BUSY",
                "A local-media picker is already open.",
                null,
            )
            return
        }
        val picker = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "video/*"
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf(
                    "video/*",
                    "application/x-matroska",
                    "application/vnd.apple.mpegurl",
                ),
            )
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
            )
        }
        pendingLocalMediaResult = result
        try {
            startActivityForResult(picker, LOCAL_MEDIA_PICKER_REQUEST_CODE)
        } catch (error: ActivityNotFoundException) {
            pendingLocalMediaResult = null
            result.error(
                "LOCAL_MEDIA_PICKER_UNAVAILABLE",
                "This device does not provide a compatible file picker.",
                null,
            )
        } catch (error: Throwable) {
            pendingLocalMediaResult = null
            result.error("LOCAL_MEDIA_PICKER", error.message, null)
        }
    }

    private fun openExternalWebPage(
        uriValue: String?,
        result: MethodChannel.Result,
    ) {
        val raw = uriValue?.trim().orEmpty()
        val uri = runCatching { Uri.parse(raw) }.getOrNull()
        if (
            uri == null ||
            !uri.scheme.equals("https", ignoreCase = true) ||
            uri.host.isNullOrBlank() ||
            !uri.userInfo.isNullOrEmpty() ||
            !uri.query.isNullOrEmpty()
        ) {
            result.error(
                "EXTERNAL_WEB_URI",
                "A public HTTPS page is required.",
                null,
            )
            return
        }
        val viewIntent = Intent(Intent.ACTION_VIEW, uri).apply {
            addCategory(Intent.CATEGORY_BROWSABLE)
        }
        if (viewIntent.resolveActivity(packageManager) == null) {
            result.success(false)
            return
        }
        try {
            startActivity(viewIntent)
            result.success(true)
        } catch (_: ActivityNotFoundException) {
            result.success(false)
        } catch (_: SecurityException) {
            result.success(false)
        }
    }

    private fun openExternalPlayer(
        uriValue: String?,
        localPath: String?,
        mimeType: String?,
        packageName: String?,
        result: MethodChannel.Result,
    ) {
        val mediaUri = try {
            when {
                !localPath.isNullOrBlank() -> {
                    val root = File(filesDir, "offline_downloads").canonicalFile
                    val selected = File(localPath).canonicalFile
                    val rootPrefix = root.path + File.separator
                    require(selected.isFile && selected.path.startsWith(rootPrefix)) {
                        "Only completed TetoTV offline downloads can be shared."
                    }
                    FileProvider.getUriForFile(
                        this,
                        "${applicationContext.packageName}.fileprovider",
                        selected,
                    )
                }
                !uriValue.isNullOrBlank() -> {
                    val parsed = Uri.parse(uriValue)
                    require(parsed.userInfo.isNullOrBlank() && parsed.fragment.isNullOrBlank()) {
                        "The selected media URI is not safe to share."
                    }
                    when (parsed.scheme?.lowercase()) {
                        "http",
                        "https" -> require(!parsed.host.isNullOrBlank()) {
                            "The selected media URI has no host."
                        }
                        ContentResolver.SCHEME_CONTENT -> require(!parsed.authority.isNullOrBlank()) {
                            "The selected content URI has no provider."
                        }
                        else -> error("This media type cannot be opened externally.")
                    }
                    parsed
                }
                else -> error("No media was selected.")
            }
        } catch (error: Throwable) {
            result.error("EXTERNAL_PLAYER_URI", error.message, null)
            return
        }
        val safeMimeType = mimeType
            ?.trim()
            ?.lowercase()
            ?.takeIf { it.startsWith("video/") || it.startsWith("application/") }
            ?: "video/*"
        val requestedPackage = packageName?.trim()?.takeIf { it.isNotEmpty() }
        if (
            requestedPackage != null &&
            !requestedPackage.matches(Regex("[A-Za-z0-9_]+(?:\\.[A-Za-z0-9_]+)+"))
        ) {
            result.error(
                "EXTERNAL_PLAYER_PACKAGE",
                "The selected player package is invalid.",
                null,
            )
            return
        }
        val viewIntent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(mediaUri, safeMimeType)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            clipData = android.content.ClipData.newRawUri("TetoTV media", mediaUri)
            requestedPackage?.let(::setPackage)
        }
        if (requestedPackage != null) {
            try {
                @Suppress("DEPRECATION")
                packageManager.getApplicationInfo(requestedPackage, 0)
            } catch (_: PackageManager.NameNotFoundException) {
                result.error(
                    "EXTERNAL_PLAYER_MISSING",
                    "The selected video player is no longer installed.",
                    null,
                )
                return
            }
        }
        if (viewIntent.resolveActivity(packageManager) == null) {
            result.error(
                if (requestedPackage == null) {
                    "EXTERNAL_PLAYER_MISSING"
                } else {
                    "EXTERNAL_PLAYER_CANNOT_OPEN"
                },
                if (requestedPackage == null) {
                    "Install a compatible video player and try again."
                } else {
                    "The selected player cannot open this stream type."
                },
                null,
            )
            return
        }
        val appProxyHandoff = ExternalPlaybackProxyPolicy.isTetoWebProxyUri(
            mediaUri.toString(),
        )
        if (appProxyHandoff && !ExternalPlaybackProxyService.start(applicationContext)) {
            result.error(
                "EXTERNAL_PLAYER_PROXY_KEEP_ALIVE",
                "TetoTV could not keep this web stream available to the selected player.",
                null,
            )
            return
        }
        try {
            if (appProxyHandoff) {
                externalProxyHandoffActive = true
                externalProxyHandoffBackgrounded = false
            }
            if (viewIntent.`package` == null) {
                startActivity(Intent.createChooser(viewIntent, "Open with video player"))
            } else {
                startActivity(viewIntent)
            }
            result.success(true)
        } catch (error: ActivityNotFoundException) {
            if (appProxyHandoff) finishExternalProxyHandoff(notifyDart = false)
            result.error(
                "EXTERNAL_PLAYER_MISSING",
                "Install a compatible video player and try again.",
                null,
            )
        } catch (error: Throwable) {
            if (appProxyHandoff) finishExternalProxyHandoff(notifyDart = false)
            result.error("EXTERNAL_PLAYER_OPEN", error.message, null)
        }
    }

    override fun onPause() {
        if (externalProxyHandoffActive) externalProxyHandoffBackgrounded = true
        super.onPause()
    }

    override fun onResume() {
        super.onResume()
        if (externalProxyHandoffActive && externalProxyHandoffBackgrounded) {
            finishExternalProxyHandoff(notifyDart = true)
        }
    }

    private fun finishExternalProxyHandoff(notifyDart: Boolean) {
        externalProxyHandoffActive = false
        externalProxyHandoffBackgrounded = false
        ExternalPlaybackProxyService.stop(applicationContext)
        if (notifyDart && ::channel.isInitialized) {
            channel.invokeMethod("externalPlayerReturned", null)
        }
    }

    @Suppress("DEPRECATION")
    private fun listExternalPlayers(): List<Map<String, String>> {
        val probes = listOf(
            Intent(Intent.ACTION_VIEW).apply { type = "video/*" },
            Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(Uri.parse("content://dev.tetotv.player/video.mkv"), "video/*")
            },
            Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(Uri.parse("https://media.tetotv.invalid/video.mkv"), "video/*")
            },
        )
        val players = linkedMapOf<String, String>()
        for (probe in probes) {
            for (resolved in packageManager.queryIntentActivities(
                probe,
                PackageManager.MATCH_DEFAULT_ONLY,
            )) {
                val activity = resolved.activityInfo ?: continue
                val playerPackage = activity.packageName?.trim().orEmpty()
                if (
                    playerPackage.isEmpty() ||
                    playerPackage == applicationContext.packageName ||
                    !activity.enabled ||
                    !activity.exported
                ) continue
                val label = resolved.loadLabel(packageManager)
                    ?.toString()
                    ?.trim()
                    ?.take(80)
                    .orEmpty()
                if (label.isNotEmpty()) players.putIfAbsent(playerPackage, label)
            }
        }
        return players.entries
            .sortedBy { it.value.lowercase() }
            .map { (playerPackage, label) ->
                mapOf("packageName" to playerPackage, "label" to label)
            }
    }

    @Suppress("DEPRECATION")
    private fun playInAppTrailer(
        provider: String?,
        videoId: String?,
        title: String?,
        result: MethodChannel.Result,
    ) {
        if (pendingTrailerResult != null) {
            result.error("TRAILER_BUSY", "A trailer is already open.", null)
            return
        }
        val request = TrailerPlaybackPolicy.request(provider, videoId, title)
        if (request == null) {
            result.error("TRAILER_INVALID", "This trailer is not supported.", null)
            return
        }
        val intent = Intent(this, TrailerPlayerActivity::class.java).apply {
            putExtra(TrailerPlayerActivity.EXTRA_PROVIDER, request.provider)
            putExtra(TrailerPlayerActivity.EXTRA_VIDEO_ID, request.videoId)
            putExtra(TrailerPlayerActivity.EXTRA_TITLE, request.title)
        }
        pendingTrailerResult = result
        try {
            startActivityForResult(intent, TRAILER_PLAYER_REQUEST_CODE)
        } catch (error: Throwable) {
            pendingTrailerResult = null
            result.error("TRAILER_OPEN", "The trailer could not open.", error.message)
        }
    }

    private fun localMediaMetadata(
        uri: Uri,
        persistedReadPermission: Boolean,
    ): Map<String, Any?> {
        require(uri.scheme == ContentResolver.SCHEME_CONTENT) {
            "Android returned an unsupported local-media URI."
        }
        var displayName: String? = null
        var size: Long? = null
        contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (nameIndex >= 0 && !cursor.isNull(nameIndex)) {
                    displayName = cursor.getString(nameIndex)?.take(300)
                }
                if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                    size = cursor.getLong(sizeIndex).coerceAtLeast(0L)
                }
            }
        }
        return mapOf(
            "uri" to uri.toString(),
            "name" to displayName.orEmpty().ifBlank { "Local video" },
            "mimeType" to contentResolver.getType(uri),
            "size" to size,
            "persistedReadPermission" to persistedReadPermission,
        )
    }

    /**
     * Remove only Android-designated cache roots. Persistent application files
     * (databases, encrypted credentials, preferences, sources, and history)
     * are deliberately outside these roots and must never be traversed here.
     */
    private fun clearAppCache(): Long {
        DirectTorrentBridge.stopAllBlocking()
        val cacheRoots = buildList {
            add(cacheDir)
            externalCacheDirs.filterNotNull().forEach(::add)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                add(createDeviceProtectedStorageContext().cacheDir)
            }
        }
        return AppStoragePolicy.clearCacheRoots(cacheRoots)
    }

    private fun clearAppCacheAsync(result: MethodChannel.Result) {
        Thread(
            {
                val outcome = runCatching(::clearAppCache)
                runOnUiThread {
                    outcome.onSuccess(result::success).onFailure { error ->
                        result.error(
                            "CACHE_CLEAR_FAILED",
                            "TetoTV could not clear its cache.",
                            error.message,
                        )
                    }
                }
            },
            "TetoTV-cache-cleaner",
        ).apply {
            isDaemon = true
            start()
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == TRAILER_PLAYER_REQUEST_CODE) {
            val pending = pendingTrailerResult
            pendingTrailerResult = null
            pending?.success(resultCode == RESULT_OK)
            return
        }
        if (requestCode == LOCAL_MEDIA_PICKER_REQUEST_CODE) {
            val pending = pendingLocalMediaResult
            pendingLocalMediaResult = null
            if (pending == null) return
            val uri = data?.data
            if (resultCode != RESULT_OK || uri == null) {
                pending.success(null)
                return
            }
            if (
                uri.scheme != ContentResolver.SCHEME_CONTENT ||
                uri.authority.isNullOrBlank() ||
                uri.userInfo != null ||
                uri.fragment != null
            ) {
                pending.error(
                    "LOCAL_MEDIA_URI",
                    "Android returned an unsupported local-media URI.",
                    null,
                )
                return
            }
            val hasReadGrant =
                data.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0
            val metadata = runCatching {
                localMediaMetadata(uri, persistedReadPermission = false)
            }.getOrElse { error ->
                pending.error(
                    "LOCAL_MEDIA_METADATA",
                    "The selected video could not be read.",
                    error.message,
                )
                return
            }
            val grantPersisted = hasReadGrant && runCatching {
                contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION,
                )
            }.isSuccess
            val persistedReadPermission = grantPersisted ||
                runCatching {
                    contentResolver.persistedUriPermissions.any {
                        it.uri == uri && it.isReadPermission
                    }
                }.getOrDefault(false)
            if (persistedReadPermission) {
                runCatching {
                    contentResolver.persistedUriPermissions
                        .filter { permission ->
                            permission.isReadPermission && permission.uri != uri
                        }
                        .forEach { permission ->
                            runCatching {
                                contentResolver.releasePersistableUriPermission(
                                    permission.uri,
                                    Intent.FLAG_GRANT_READ_URI_PERMISSION,
                                )
                            }
                        }
                }
            }
            pending.success(
                metadata + ("persistedReadPermission" to persistedReadPermission),
            )
            return
        }
        if (requestCode == VOICE_SEARCH_REQUEST_CODE) {
            val pending = pendingVoiceSearchResult
            pendingVoiceSearchResult = null
            if (pending == null) return
            if (resultCode != RESULT_OK) {
                pending.success(null)
                return
            }
            val matches = data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)
            pending.success(matches?.firstOrNull()?.trim()?.takeIf(String::isNotBlank))
            return
        }
        if (requestCode == APK_INSTALL_PERMISSION_REQUEST_CODE) {
            val pending = pendingApkInstallResult
            val path = pendingApkPath
            pendingApkInstallResult = null
            pendingApkPath = null
            if (pending == null || path == null) return
            if (
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                !packageManager.canRequestPackageInstalls()
            ) {
                pending.error(
                    "APK_INSTALL_PERMISSION",
                    "Allow TetoTV to install unknown apps, then try again.",
                    null,
                )
                return
            }
            try {
                // The permission screen can remain open for an arbitrary
                // amount of time. Re-inspect immediately before granting the
                // package installer access so a stale/replaced download is
                // never launched based on the earlier verdict.
                val inspection = inspectApk(path)
                if (inspection["compatible"] != true) {
                    val issues = (inspection["issues"] as? List<*>)
                        ?.filterIsInstance<String>()
                        ?.joinToString(" ")
                        .orEmpty()
                    pending.error(
                        "APK_INCOMPATIBLE",
                        issues.ifBlank {
                            "The downloaded APK is no longer valid for this device."
                        },
                        inspection,
                    )
                    return
                }
                launchApkInstaller(File(path))
                pending.success("launched")
            } catch (error: Throwable) {
                pending.error("APK_INSTALL", error.message, null)
            }
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != VOICE_SEARCH_PERMISSION_REQUEST_CODE) return
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            beginEmbeddedVoiceSearch()
        } else {
            finishEmbeddedVoiceSearch(
                value = null,
                errorMessage = "Microphone permission is required for voice search.",
            )
        }
    }

    @Suppress("DEPRECATION")
    private fun startVoiceSearch(result: MethodChannel.Result) {
        if (pendingVoiceSearchResult != null) {
            result.error("VOICE_SEARCH_BUSY", "Voice search is already open.", null)
            return
        }
        // Prefer the embedded recognizer. Several Google TV builds advertise
        // a recognition Activity that immediately closes when launched from a
        // TV app, while their SpeechRecognizer service works correctly.
        if (SpeechRecognizer.isRecognitionAvailable(this)) {
            startEmbeddedVoiceSearch(result)
            return
        }
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
            )
            putExtra(RecognizerIntent.EXTRA_PROMPT, "Search anime")
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 3)
        }
        if (intent.resolveActivity(packageManager) == null) {
            startEmbeddedVoiceSearch(result)
            return
        }
        pendingVoiceSearchResult = result
        try {
            startActivityForResult(intent, VOICE_SEARCH_REQUEST_CODE)
        } catch (_: ActivityNotFoundException) {
            pendingVoiceSearchResult = null
            result.error(
                "VOICE_SEARCH_UNAVAILABLE",
                "This TV does not have a speech recognition service installed.",
                null,
            )
        } catch (error: Throwable) {
            pendingVoiceSearchResult = null
            result.error("VOICE_SEARCH", error.message, null)
        }
    }

    private fun startEmbeddedVoiceSearch(result: MethodChannel.Result) {
        if (!SpeechRecognizer.isRecognitionAvailable(this)) {
            result.error(
                "VOICE_SEARCH_UNAVAILABLE",
                "This device does not have a speech recognition service installed.",
                null,
            )
            return
        }
        pendingVoiceSearchResult = result
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) !=
                PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(
                arrayOf(android.Manifest.permission.RECORD_AUDIO),
                VOICE_SEARCH_PERMISSION_REQUEST_CODE,
            )
            return
        }
        beginEmbeddedVoiceSearch()
    }

    private fun beginEmbeddedVoiceSearch() {
        if (pendingVoiceSearchResult == null) return
        speechRecognizer?.destroy()
        voiceSearchHandler.removeCallbacks(voiceSearchTimeout)
        voiceSearchHandler.postDelayed(voiceSearchTimeout, VOICE_SEARCH_TIMEOUT_MS)
        speechRecognizer = SpeechRecognizer.createSpeechRecognizer(this).also { recognizer ->
            recognizer.setRecognitionListener(object : RecognitionListener {
                override fun onReadyForSpeech(params: Bundle?) = Unit
                override fun onBeginningOfSpeech() = Unit
                override fun onRmsChanged(rmsdB: Float) = Unit
                override fun onBufferReceived(buffer: ByteArray?) = Unit
                override fun onEndOfSpeech() = Unit
                override fun onEvent(eventType: Int, params: Bundle?) = Unit
                override fun onPartialResults(partialResults: Bundle?) = Unit

                override fun onError(error: Int) {
                    finishEmbeddedVoiceSearch(
                        value = null,
                        errorMessage = when (error) {
                            SpeechRecognizer.ERROR_NO_MATCH -> "No title was recognized."
                            SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "No speech was heard."
                            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS ->
                                "Microphone permission is required for voice search."
                            else -> "Voice search could not recognize a title."
                        },
                    )
                }

                override fun onResults(results: Bundle?) {
                    val matches = results
                        ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                    finishEmbeddedVoiceSearch(value = matches?.firstOrNull())
                }
            })
            recognizer.startListening(
                Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                    putExtra(
                        RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                        RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
                    )
                    putExtra(RecognizerIntent.EXTRA_PROMPT, "Search anime")
                    putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 3)
                },
            )
        }
    }

    private fun finishEmbeddedVoiceSearch(
        value: String?,
        errorMessage: String? = null,
    ) {
        val pending = pendingVoiceSearchResult
        pendingVoiceSearchResult = null
        voiceSearchHandler.removeCallbacks(voiceSearchTimeout)
        speechRecognizer?.cancel()
        speechRecognizer?.destroy()
        speechRecognizer = null
        if (pending == null) return
        if (errorMessage == null) {
            pending.success(value)
        } else {
            pending.error("VOICE_SEARCH", errorMessage, null)
        }
    }

    @Suppress("DEPRECATION")
    private fun appVersion(): Map<String, Any> {
        val info = packageManager.getPackageInfo(packageName, 0)
        val versionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            info.versionCode.toLong()
        }
        return mapOf(
            "versionName" to (info.versionName ?: "unknown"),
            "versionCode" to versionCode,
        )
    }

    @Suppress("DEPRECATION")
    private fun installApk(path: String?, result: MethodChannel.Result) {
        if (pendingApkInstallResult != null) {
            result.error("APK_INSTALL_BUSY", "An update install is already pending.", null)
            return
        }
        val file = path?.let(::File)
        if (file == null || !file.isFile || !isUpdateCacheFile(file)) {
            result.error("APK_INSTALL_FILE", "The downloaded update could not be found.", null)
            return
        }
        val inspection = inspectApk(file.absolutePath)
        if (inspection["compatible"] != true) {
            val issues = (inspection["issues"] as? List<*>)
                ?.filterIsInstance<String>()
                ?.joinToString(" ")
                .orEmpty()
            result.error(
                "APK_INCOMPATIBLE",
                issues.ifBlank { "The downloaded APK is not compatible with this device." },
                inspection,
            )
            return
        }
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            pendingApkInstallResult = result
            pendingApkPath = file.absolutePath
            try {
                startActivityForResult(
                    Intent(
                        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.parse("package:$packageName"),
                    ),
                    APK_INSTALL_PERMISSION_REQUEST_CODE,
                )
            } catch (error: Throwable) {
                pendingApkInstallResult = null
                pendingApkPath = null
                result.error("APK_INSTALL_PERMISSION", error.message, null)
            }
            return
        }
        launchApkInstaller(file)
        result.success("launched")
    }

    @Suppress("DEPRECATION")
    private fun inspectApk(path: String?): Map<String, Any?> {
        val issues = mutableListOf<String>()
        val file = path?.let(::File)
        if (file == null || !file.isFile || !isUpdateCacheFile(file)) {
            return mapOf(
                "compatible" to false,
                "issues" to listOf("The downloaded update file could not be found."),
                "deviceAbis" to Build.SUPPORTED_ABIS.toList(),
            )
        }
        if (file.length() !in 1L..MAX_UPDATE_APK_BYTES) {
            return mapOf(
                "compatible" to false,
                "issues" to listOf(
                    "The downloaded update has an invalid file size.",
                ),
                "deviceAbis" to Build.SUPPORTED_ABIS.toList(),
            )
        }
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES or PackageManager.GET_CONFIGURATIONS
        } else {
            PackageManager.GET_SIGNATURES or PackageManager.GET_CONFIGURATIONS
        }
        val archive = packageManager.getPackageArchiveInfo(file.absolutePath, flags)
        if (archive == null) {
            return mapOf(
                "compatible" to false,
                "issues" to listOf("Android could not read this APK. The download may be damaged."),
                "deviceAbis" to Build.SUPPORTED_ABIS.toList(),
            )
        }
        val installed = packageManager.getPackageInfo(packageName, flags)
        val archiveVersion = packageVersionCode(archive)
        val installedVersion = packageVersionCode(installed)
        val archiveVersionName = archive.versionName.orEmpty()
        val installedVersionName = installed.versionName.orEmpty()
        val minSdk = archive.applicationInfo?.minSdkVersion ?: 1
        val archiveAbis = runCatching {
            ZipFile(file).use { zip ->
                zip.entries().asSequence()
                    .mapNotNull { entry ->
                        Regex("^lib/([^/]+)/.+").find(entry.name)?.groupValues?.get(1)
                    }
                    .toSortedSet()
                    .toList()
            }
        }.getOrElse {
            issues.add("The APK archive is damaged and could not be inspected.")
            emptyList()
        }
        val deviceAbis = Build.SUPPORTED_ABIS.toList()
        val signerMatches = signerDigests(archive).isNotEmpty() &&
            signerDigests(archive) == signerDigests(installed)
        val identityIssues = appUpdateIdentityIssues(
            archiveVersionCode = archiveVersion,
            archiveVersionName = archiveVersionName,
            installedVersionCode = installedVersion,
            installedVersionName = installedVersionName,
            signerMatches = signerMatches,
        )

        if (archive.packageName != packageName) {
            issues.add("The APK belongs to ${archive.packageName}, not TetoTV.")
        }
        if (AppUpdateIdentityIssue.VERSION_DOWNGRADE in identityIssues) {
            issues.add(
                "Android blocks in-place downgrades: target build $archiveVersion is lower than installed build $installedVersion. Developer mode cannot bypass this device security rule.",
            )
        }
        if (AppUpdateIdentityIssue.SAME_BUILD in identityIssues) {
            issues.add(
                "TetoTV $installedVersionName (build $installedVersion) is already installed.",
            )
        }
        if (AppUpdateIdentityIssue.SIGNER_MISMATCH in identityIssues) {
            issues.add("The APK signing certificate does not match the installed TetoTV app.")
        }
        if (minSdk > Build.VERSION.SDK_INT) {
            issues.add("This APK requires Android API $minSdk; this device is API ${Build.VERSION.SDK_INT}.")
        }
        if (archiveAbis.isNotEmpty() && archiveAbis.none(deviceAbis::contains)) {
            issues.add(
                "The APK supports ${archiveAbis.joinToString()}, but this device uses ${deviceAbis.joinToString()}.",
            )
        }
        archive.reqFeatures.orEmpty()
            .filter { it.name != null && it.flags and FeatureInfo.FLAG_REQUIRED != 0 }
            .filterNot { packageManager.hasSystemFeature(it.name) }
            .forEach { issues.add("This device is missing required feature ${it.name}.") }
        val availableBytes = StatFs(file.parentFile?.absolutePath ?: cacheDir.absolutePath).availableBytes
        if (availableBytes < file.length() * 2 + 20L * 1024L * 1024L) {
            issues.add("There is not enough free storage to safely install this update.")
        }
        return mapOf(
            "compatible" to issues.isEmpty(),
            "issues" to issues,
            "issueCodes" to identityIssues.map { issue ->
                when (issue) {
                    AppUpdateIdentityIssue.VERSION_DOWNGRADE -> "version_downgrade"
                    AppUpdateIdentityIssue.SAME_BUILD -> "same_build"
                    AppUpdateIdentityIssue.SIGNER_MISMATCH -> "signer_mismatch"
                }
            }.sorted(),
            "packageName" to archive.packageName,
            "versionCode" to archiveVersion,
            "versionName" to archiveVersionName,
            "installedVersionCode" to installedVersion,
            "installedVersionName" to installedVersionName,
            "minSdk" to minSdk,
            "archiveAbis" to archiveAbis,
            "deviceAbis" to deviceAbis,
            "signerMatches" to signerMatches,
        )
    }

    @Suppress("DEPRECATION")
    private fun packageVersionCode(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode
        else info.versionCode.toLong()

    @Suppress("DEPRECATION")
    private fun signerDigests(info: PackageInfo): Set<String> {
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.signingInfo?.apkContentsSigners.orEmpty()
        } else {
            info.signatures.orEmpty()
        }
        return signatures.mapTo(mutableSetOf()) { signature ->
            MessageDigest.getInstance("SHA-256")
                .digest(signature.toByteArray())
                .joinToString("") { byte -> "%02x".format(byte) }
        }
    }

    private fun isUpdateCacheFile(file: File): Boolean {
        val updateDirectory = File(cacheDir, "updates").canonicalFile
        val candidate = file.canonicalFile
        return candidate.path.startsWith(updateDirectory.path + File.separator)
    }

    private fun launchApkInstaller(file: File) {
        val apkUri = FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            file,
        )
        val intent = Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
            data = apkUri
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            putExtra(Intent.EXTRA_NOT_UNKNOWN_SOURCE, true)
            putExtra(Intent.EXTRA_RETURN_RESULT, false)
        }
        if (intent.resolveActivity(packageManager) == null) {
            throw IllegalStateException("No Android package installer is available on this TV.")
        }
        startActivity(intent)
    }

    private fun createMediaSession() {
        mediaSession = MediaSessionCompat(this, "TetoTV").apply {
            setFlags(
                MediaSessionCompat.FLAG_HANDLES_MEDIA_BUTTONS or
                    MediaSessionCompat.FLAG_HANDLES_TRANSPORT_CONTROLS,
            )
            setCallback(object : MediaSessionCompat.Callback() {
                override fun onPlay() = invokePlayer("play")
                override fun onPause() = invokePlayer("pause")
                override fun onSeekTo(pos: Long) = invokePlayer("seekTo", pos)
                override fun onSkipToNext() = invokePlayer("next")
                override fun onSkipToPrevious() = invokePlayer("previous")
                override fun onFastForward() =
                    invokePlayer("seekBy", mediaSeekForwardIncrementMs)
                override fun onRewind() = invokePlayer("seekBy", -mediaSeekBackIncrementMs)
            })
            val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
            if (launchIntent != null) {
                setSessionActivity(android.app.PendingIntent.getActivity(
                    this@MainActivity,
                    0,
                    launchIntent,
                    android.app.PendingIntent.FLAG_IMMUTABLE or
                        android.app.PendingIntent.FLAG_UPDATE_CURRENT,
                ))
            }
            isActive = false
        }
    }

    private fun invokePlayer(action: String, value: Long? = null) {
        runOnUiThread {
            channel.invokeMethod("mediaAction", mapOf("action" to action, "value" to value))
        }
    }

    private fun updateMediaSession(data: Map<String, Any?>) {
        val title = data["title"] as? String ?: "TetoTV"
        val subtitle = data["subtitle"] as? String ?: ""
        val duration = (data["durationMs"] as? Number)?.toLong() ?: 0L
        val position = (data["positionMs"] as? Number)?.toLong() ?: 0L
        val playing = data["playing"] as? Boolean ?: false
        val playbackRate = (data["playbackRate"] as? Number)
            ?.toFloat()
            ?.coerceIn(0.5f, 2f)
            ?: 1f
        (data["seekBackMs"] as? Number)?.toLong()?.let {
            mediaSeekBackIncrementMs =
                it.coerceIn(MIN_SEEK_INCREMENT_MS, MAX_SEEK_INCREMENT_MS)
        }
        (data["seekForwardMs"] as? Number)?.toLong()?.let {
            mediaSeekForwardIncrementMs =
                it.coerceIn(MIN_SEEK_INCREMENT_MS, MAX_SEEK_INCREMENT_MS)
        }

        mediaSession.setMetadata(
            MediaMetadataCompat.Builder()
                .putString(MediaMetadataCompat.METADATA_KEY_TITLE, title)
                .putString(MediaMetadataCompat.METADATA_KEY_DISPLAY_SUBTITLE, subtitle)
                .putLong(MediaMetadataCompat.METADATA_KEY_DURATION, duration)
                .build(),
        )
        val actions = PlaybackStateCompat.ACTION_PLAY or
            PlaybackStateCompat.ACTION_PAUSE or
            PlaybackStateCompat.ACTION_PLAY_PAUSE or
            PlaybackStateCompat.ACTION_SEEK_TO or
            PlaybackStateCompat.ACTION_FAST_FORWARD or
            PlaybackStateCompat.ACTION_REWIND or
            PlaybackStateCompat.ACTION_SKIP_TO_NEXT or
            PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS
        mediaSession.setPlaybackState(
            PlaybackStateCompat.Builder()
                .setActions(actions)
                .setState(
                    if (playing) PlaybackStateCompat.STATE_PLAYING else PlaybackStateCompat.STATE_PAUSED,
                    position,
                    if (playing) playbackRate else 0f,
                )
                .build(),
        )
        mediaSession.isActive = true
    }

    private fun clearMediaSession() {
        if (!::mediaSession.isInitialized) return
        mediaSession.setMetadata(null)
        mediaSession.setPlaybackState(
            PlaybackStateCompat.Builder()
                .setActions(0L)
                .setState(PlaybackStateCompat.STATE_NONE, 0L, 0f)
                .build(),
        )
        mediaSession.isActive = false
    }

    private fun deviceProfile(): Map<String, Any?> {
        val displayManager = getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
        val display = displayManager.getDisplay(android.view.Display.DEFAULT_DISPLAY)
        val modes = display?.supportedModes?.map {
            mapOf(
                "id" to it.modeId,
                "width" to it.physicalWidth,
                "height" to it.physicalHeight,
                "refreshRate" to it.refreshRate.toDouble(),
            )
        } ?: emptyList()
        val hdrTypes = display?.hdrCapabilities?.supportedHdrTypes?.toList() ?: emptyList()

        val codecs = mutableListOf<Map<String, Any?>>()
        MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos
            .filter { !it.isEncoder }
            .forEach { info ->
                info.supportedTypes
                    .filter { it.startsWith("video/") }
                    .forEach { mime ->
                        val capabilities = runCatching {
                            info.getCapabilitiesForType(mime)
                        }.getOrNull()
                        val videoCapabilities = capabilities?.videoCapabilities
                        val profiles = capabilities?.profileLevels
                            ?.map { level -> level.profile }
                            .orEmpty()
                        val normalizedMime = mime.lowercase()
                        val tenBit = when (normalizedMime) {
                            "video/hevc", "video/av01" ->
                                profiles.any { profile -> profile != 1 }
                            "video/x-vnd.on2.vp9" ->
                                profiles.any { profile ->
                                    profile == 4 || profile == 8 || profile >= 4096
                                }
                            else -> false
                        }
                        codecs.add(
                            mapOf(
                                "name" to info.name,
                                "mime" to normalizedMime,
                                "hardware" to isHardwareAccelerated(info),
                                "tenBit" to tenBit,
                                "maxWidth" to runCatching {
                                    videoCapabilities?.supportedWidths?.upper ?: 0
                                }.getOrDefault(0),
                                "maxHeight" to runCatching {
                                    videoCapabilities?.supportedHeights?.upper ?: 0
                                }.getOrDefault(0),
                            ),
                        )
                    }
            }

        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val audioOutputs = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).map { device ->
            mapOf(
                "type" to device.type,
                "name" to (device.productName?.toString() ?: "Audio output"),
                "channels" to device.channelCounts.toList(),
                "sampleRates" to device.sampleRates.toList(),
                "encodings" to device.encodings.toList(),
                "hdmi" to (device.type == AudioDeviceInfo.TYPE_HDMI ||
                    device.type == AudioDeviceInfo.TYPE_HDMI_ARC ||
                    (Build.VERSION.SDK_INT >= 31 && device.type == AudioDeviceInfo.TYPE_HDMI_EARC)),
            )
        }

        return mapOf(
            "manufacturer" to Build.MANUFACTURER,
            "model" to Build.MODEL,
            "sdk" to Build.VERSION.SDK_INT,
            "abis" to Build.SUPPORTED_ABIS.toList(),
            "displayModes" to modes,
            "hdrTypes" to hdrTypes,
            "codecs" to codecs,
            "audioOutputs" to audioOutputs,
        )
    }

    private fun isHardwareAccelerated(info: MediaCodecInfo): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) return info.isHardwareAccelerated
        val name = info.name.lowercase()
        return !(name.startsWith("omx.google") || name.startsWith("c2.android") ||
            name.contains("ffmpeg") || name.contains("software"))
    }

    private fun setPreferredFrameRate(fps: Double): Int {
        if (fps <= 0.0) return 0
        val display = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            this.display
        } else {
            @Suppress("DEPRECATION")
            windowManager.defaultDisplay
        } ?: return 0
        val current = display.mode
        val target = display.supportedModes
            .filter {
                it.physicalWidth == current.physicalWidth &&
                    it.physicalHeight == current.physicalHeight
            }
            .minByOrNull { mode ->
                minOf(
                    abs(mode.refreshRate - fps),
                    abs(mode.refreshRate - fps * 2),
                )
            } ?: return 0
        window.attributes = window.attributes.apply { preferredDisplayModeId = target.modeId }
        return target.modeId
    }

    @SuppressLint("RestrictedApi")
    private fun publishWatchNext(data: Map<String, Any?>): Long? {
        val mediaId = (data["mediaId"] as? Number)?.toLong() ?: return null
        val episode = (data["episode"] as? Number)?.toInt() ?: 1
        if (mediaId <= 0L || episode <= 0) return null
        val title = data["title"] as? String ?: return null
        val description = data["description"] as? String ?: "Continue watching on TetoTV"
        val poster = (data["posterUrl"] as? String)?.let(Uri::parse)
        val duration = (data["durationMs"] as? Number)?.toInt() ?: 0
        val position = (data["positionMs"] as? Number)?.toInt() ?: 0
        val deepLink = AppDeepLinkPolicy.animeUri(mediaId, episode).toUri()

        val builder = WatchNextProgram.Builder()
            .setType(TvContractCompat.WatchNextPrograms.TYPE_TV_EPISODE)
            .setWatchNextType(TvContractCompat.WatchNextPrograms.WATCH_NEXT_TYPE_CONTINUE)
            .setTitle(title)
            .setEpisodeNumber(episode)
            .setDescription(description)
            .setInternalProviderId("$mediaId:$episode")
            .setIntentUri(deepLink)
            .setLastPlaybackPositionMillis(position)
            .setDurationMillis(duration)
            .setLastEngagementTimeUtcMillis(System.currentTimeMillis())
        if (poster != null) builder.setPosterArtUri(poster)

        val preferences = getSharedPreferences("watch_next", Context.MODE_PRIVATE)
        val key = watchNextKey(mediaId)
        val existingId = migrateLegacyWatchNextPrograms(
            preferences = preferences,
            mediaId = mediaId,
            episode = episode,
        )
        if (existingId > 0) {
            val existingUri = ContentUris.withAppendedId(
                TvContractCompat.WatchNextPrograms.CONTENT_URI,
                existingId,
            )
            if (contentResolver.update(existingUri, builder.build().toContentValues(), null, null) > 0) {
                return existingId
            }
        }
        val uri = contentResolver.insert(
            TvContractCompat.WatchNextPrograms.CONTENT_URI,
            builder.build().toContentValues(),
        ) ?: return null
        return ContentUris.parseId(uri).also { id -> preferences.edit { putLong(key, id) } }
    }

    private fun migrateLegacyWatchNextPrograms(
        preferences: android.content.SharedPreferences,
        mediaId: Long,
        episode: Int,
    ): Long {
        val key = watchNextKey(mediaId)
        val legacyPrefix = "program_${mediaId}_"
        var reusableId = preferences.getLong(key, -1L)
        if (reusableId <= 0L) {
            reusableId = preferences.getLong("$legacyPrefix$episode", -1L)
        }
        val legacyKeys = preferences.all.keys.filter { it.startsWith(legacyPrefix) }
        if (legacyKeys.isEmpty()) return reusableId
        val editor = preferences.edit()
        for (legacyKey in legacyKeys) {
            val legacyId = preferences.getLong(legacyKey, -1L)
            if (legacyId > 0L && legacyId != reusableId) deleteWatchNextProgram(legacyId)
            editor.remove(legacyKey)
        }
        if (reusableId > 0L) editor.putLong(key, reusableId)
        editor.apply()
        return reusableId
    }

    private fun removeWatchNext(data: Map<String, Any?>): Boolean {
        val mediaId = (data["mediaId"] as? Number)?.toLong() ?: return false
        val preferences = getSharedPreferences("watch_next", Context.MODE_PRIVATE)
        val key = watchNextKey(mediaId)
        val legacyPrefix = "program_${mediaId}_"
        val keys = preferences.all.keys.filter { it == key || it.startsWith(legacyPrefix) }
        var removed = false
        val editor = preferences.edit()
        for (storedKey in keys) {
            val programId = preferences.getLong(storedKey, -1L)
            if (programId > 0L) removed = deleteWatchNextProgram(programId) || removed
            editor.remove(storedKey)
        }
        editor.apply()
        return removed || keys.isNotEmpty()
    }

    private fun deleteWatchNextProgram(programId: Long): Boolean {
        val uri = ContentUris.withAppendedId(
            TvContractCompat.WatchNextPrograms.CONTENT_URI,
            programId,
        )
        return runCatching { contentResolver.delete(uri, null, null) > 0 }.getOrDefault(false)
    }

    private fun watchNextKey(mediaId: Long) = "program_$mediaId"

    private fun scheduleReminder(data: Map<String, Any?>): Boolean {
        val mediaId = (data["mediaId"] as? Number)?.toLong() ?: return false
        val episode = (data["episode"] as? Number)?.toInt() ?: return false
        val title = data["title"] as? String ?: return false
        val atMillis = (data["atMillis"] as? Number)?.toLong() ?: return false
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 5105)
        }
        val intent = Intent(this, AiringReminderReceiver::class.java).apply {
            putExtra("mediaId", mediaId)
            putExtra("episode", episode)
            putExtra("title", title)
        }
        val requestCode = ((mediaId * 31 + episode) and 0x7fffffff).toInt()
        val pending = PendingIntent.getBroadcast(
            this,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val alarm = getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarm.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMillis, pending)
        return true
    }

    /**
     * Atomically replaces automatically managed new-episode alarms. Manual
     * Calendar reminders use a different Intent identity and are not removed.
     */
    private fun syncEpisodeReleaseNotifications(data: Map<String, Any?>): Int {
        val preferences = getSharedPreferences(
            AUTO_RELEASE_REMINDER_PREFERENCES,
            Context.MODE_PRIVATE,
        )
        val previous = preferences.getStringSet(AUTO_RELEASE_REMINDER_KEYS, emptySet())
            ?.toSet()
            ?: emptySet()
        for (key in previous) {
            autoReleaseReminderPendingIntent(key, PendingIntent.FLAG_NO_CREATE)?.let { pending ->
                (getSystemService(Context.ALARM_SERVICE) as AlarmManager).cancel(pending)
                pending.cancel()
            }
        }

        val rows = data["notifications"] as? List<*> ?: emptyList<Any?>()
        val now = System.currentTimeMillis()
        val scheduledKeys = linkedSetOf<String>()
        val alarm = getSystemService(Context.ALARM_SERVICE) as AlarmManager
        for (raw in rows.take(150)) {
            val row = raw as? Map<*, *> ?: continue
            val mediaId = (row["mediaId"] as? Number)?.toLong() ?: continue
            val episode = (row["episode"] as? Number)?.toInt() ?: continue
            val atMillis = (row["atMillis"] as? Number)?.toLong() ?: continue
            val title = (row["title"] as? String)?.trim().orEmpty().take(160)
            val kind = row["kind"] as? String ?: continue
            if (
                mediaId <= 0L ||
                episode <= 0 ||
                atMillis <= now ||
                title.isEmpty() ||
                kind !in setOf("simulcast", "dub")
            ) continue
            val key = "$mediaId:$episode:$kind"
            val pending = autoReleaseReminderPendingIntent(
                key,
                PendingIntent.FLAG_UPDATE_CURRENT,
                title = title,
                mediaId = mediaId,
                episode = episode,
                kind = kind,
            ) ?: continue
            alarm.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMillis, pending)
            scheduledKeys += key
        }
        preferences.edit { putStringSet(AUTO_RELEASE_REMINDER_KEYS, scheduledKeys) }
        if (
            scheduledKeys.isNotEmpty() &&
            Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 5105)
        }
        return scheduledKeys.size
    }

    private fun autoReleaseReminderPendingIntent(
        key: String,
        flags: Int,
        title: String? = null,
        mediaId: Long? = null,
        episode: Int? = null,
        kind: String? = null,
    ): PendingIntent? {
        val parts = key.split(':')
        val resolvedMediaId = mediaId ?: parts.getOrNull(0)?.toLongOrNull() ?: return null
        val resolvedEpisode = episode ?: parts.getOrNull(1)?.toIntOrNull() ?: return null
        val resolvedKind = kind ?: parts.getOrNull(2)?.takeIf { it in setOf("simulcast", "dub") }
            ?: return null
        val intent = Intent(this, AiringReminderReceiver::class.java).apply {
            action = AUTO_RELEASE_REMINDER_ACTION
            data = Uri.Builder()
                .scheme("tetotv-notification")
                .authority("episode")
                .appendPath(resolvedMediaId.toString())
                .appendPath(resolvedEpisode.toString())
                .appendPath(resolvedKind)
                .build()
            putExtra("mediaId", resolvedMediaId)
            putExtra("episode", resolvedEpisode)
            putExtra("releaseKind", resolvedKind)
            putExtra("automaticRelease", true)
            if (!title.isNullOrBlank()) putExtra("title", title)
        }
        return PendingIntent.getBroadcast(
            this,
            key.hashCode() and 0x7fffffff,
            intent,
            flags or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    override fun onDestroy() {
        if (externalProxyHandoffActive) {
            finishExternalProxyHandoff(notifyDart = false)
        }
        pendingLocalMediaResult?.error(
            "LOCAL_MEDIA_PICKER_DESTROYED",
            "The Android TV activity closed before a video was selected.",
            null,
        )
        pendingLocalMediaResult = null
        pendingApkInstallResult?.error(
            "APK_INSTALL_DESTROYED",
            "The Android TV activity closed before the installer opened.",
            null,
        )
        pendingApkInstallResult = null
        pendingApkPath = null
        pendingVoiceSearchResult?.error(
            "VOICE_SEARCH_DESTROYED",
            "The Android TV activity closed before voice search returned.",
            null,
        )
        pendingVoiceSearchResult = null
        voiceSearchHandler.removeCallbacks(voiceSearchTimeout)
        speechRecognizer?.cancel()
        speechRecognizer?.destroy()
        speechRecognizer = null
        pendingTrailerResult?.error(
            "TRAILER_DESTROYED",
            "Trailer playback closed before it could finish.",
            null,
        )
        pendingTrailerResult = null
        if (::mediaSession.isInitialized) mediaSession.release()
        super.onDestroy()
    }

    companion object {
        private const val AUTO_RELEASE_REMINDER_PREFERENCES = "auto_release_reminders"
        private const val AUTO_RELEASE_REMINDER_KEYS = "scheduled_keys"
        private const val AUTO_RELEASE_REMINDER_ACTION =
            "dev.animetv.anime_tv.AUTO_EPISODE_RELEASE"
        private const val APK_INSTALL_PERMISSION_REQUEST_CODE = 7315
        private const val VOICE_SEARCH_REQUEST_CODE = 7316
        private const val VOICE_SEARCH_PERMISSION_REQUEST_CODE = 7317
        private const val LOCAL_MEDIA_PICKER_REQUEST_CODE = 7318
        private const val TRAILER_PLAYER_REQUEST_CODE = 7319
        private const val VOICE_SEARCH_TIMEOUT_MS = 20_000L
        private const val DEFAULT_SEEK_INCREMENT_MS = 10_000L
        private const val MIN_SEEK_INCREMENT_MS = 5_000L
        private const val MAX_SEEK_INCREMENT_MS = 60_000L
        private const val MAX_UPDATE_APK_BYTES = 512L * 1024L * 1024L
    }
}
