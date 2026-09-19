package dev.animetv.anime_tv.aniyomi

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Binder
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Parcel
import android.os.ParcelFileDescriptor
import android.os.Process
import android.os.SystemClock
import dev.animetv.anime_tv.aniyomi.compat.AniyomiCompatRuntime
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject

/** Main-process facade. Only validated DTOs and a read-only APK capability reach the isolated UID. */
class AniyomiNativeHost(context: Context, private val isDeveloperModeEnabled: () -> Boolean) {
    private val application = context.applicationContext
    private val lease = AniyomiLease { !closed && isDeveloperModeEnabled() }
    private val store = AniyomiApkStore(application)
    private val main = Handler(Looper.getMainLooper())
    private val maxConcurrentRequests = workerCapacity(Build.VERSION.SDK_INT)
    private val io = Executors.newFixedThreadPool(MAX_CONCURRENT_WORKERS)
    private val imageIo = Executors.newFixedThreadPool(MAX_CONCURRENT_IMAGE_FETCHES)
    private val sequence = AtomicLong()
    private val instancePrefix = UUID.randomUUID().toString().replace("-", "")
    @Volatile private var closed = false
    private val pending = LinkedHashMap<Long, Pending>()
    private val pendingImages = LinkedHashMap<Long, PendingImage>()
    private val cookieJars = HashMap<String, AniyomiEphemeralCookieJar>()
    private val imageCapabilities = AniyomiImageCapabilityStore()

    fun status(): Map<String, Any?> = mapOf(
        "available" to (Build.VERSION.SDK_INT >= 26 && !closed),
        "developerModeEnabled" to isDeveloperModeEnabled(),
        "isolatedProcess" to true,
        "runtime" to "experimental_http_subset",
        "runtimeRevision" to AniyomiCompatRuntime.RUNTIME_REVISION,
        "animeApiVersions" to listOf("14", "16"),
        "mangaApiVersions" to listOf("1.4", "1.5"),
        "minimumAndroidApi" to 26,
        "maxConcurrentRequests" to maxConcurrentRequests,
        "capabilities" to mapOf(
            "currentHosterFlow" to true,
            // The Flutter adapter can explicitly force a bounded sorted
            // prefix of lazy hosters in the same disposable worker request.
            "lazyVideoResolution" to true,
            "lazyHosterDeferral" to true,
            "mangaImageRequestResolution" to true,
            "opaqueMangaImageFetch" to true,
            "ephemeralCookies" to true,
            "redirects" to true,
            // Source helpers receive bounded invocation-local preferences; no
            // durable provider configuration is exposed to extension code.
            "sourcePreferences" to true,
            "javascriptEvaluation" to true,
            "hostOwnedHlsBridge" to true,
            "webView" to false,
            "nativeLibraries" to false,
        ),
        "resultLimits" to mapOf(
            "httpBodyBytes" to AniyomiPolicy.MAX_HTTP_BYTES,
            "httpMetadataBytes" to AniyomiPolicy.MAX_HTTP_REPLY_BYTES,
            "replyBytes" to 160 * 1024,
            "sources" to 32,
            "searchItems" to 100,
            "episodesOrChapters" to 2000,
            "targetedEpisodeCandidates" to 64,
            "pages" to 1000,
            "imageCapabilityCount" to AniyomiImageCapabilityStore.MAX_ENTRIES,
            "imageCapabilityTtlSeconds" to AniyomiImageCapabilityStore.TTL_MS / 1000,
            "imageBytes" to AniyomiImageFetcher.MAX_IMAGE_BYTES,
            "imageConcurrentRequests" to MAX_CONCURRENT_IMAGE_FETCHES,
            "videos" to 32,
            "tracksPerVideo" to 16,
            "hosters" to 64,
            "lazyHostersPerRequest" to AniyomiCompatRuntime.MAX_LAZY_HOSTERS_PER_REQUEST,
        ),
        "universalCompatibility" to false,
    )

    fun inspectApk(path: String, kind: String, callback: (Map<String, Any?>) -> Unit) {
        val access = runCatching { requireAvailable(); lease.issue() }.getOrElse {
            deliver(callback, errorMap("developer_mode_or_android_version_required")); return
        }
        io.execute {
            val result = runCatching {
                lease.check(access)
                val identity = store.inspect(path, kind)
                lease.check(access)
                successMap(identity)
            }.getOrElse { errorMap(safeError(it, "apk_inspection_failed")) }
            main.post {
                val final = if (runCatching { lease.check(access) }.isSuccess) result else errorMap("developer_access_revoked")
                callback(final)
            }
        }
    }

    fun approve(inspectionId: String): Map<String, Any?> = runCatching {
        requireAvailable()
        val access = lease.issue()
        val approved = store.approve(inspectionId) { lease.check(access) }
        lease.check(access)
        successMap(approved)
    }.getOrElse { errorMap(safeError(it, "approval_failed")) }

    fun listApproved(): List<Map<String, Any?>> {
        if (closed || !isDeveloperModeEnabled()) return emptyList()
        return store.listApproved().map(::jsonMap)
    }

    @Synchronized fun request(arguments: Map<*, *>, callback: (Map<String, Any?>) -> Unit) {
        val access = runCatching { requireAvailable(); lease.issue() }.getOrElse {
            deliver(callback, errorMap("developer_mode_or_android_version_required")); return
        }
        val request = runCatching { AniyomiRequestPolicy.sanitize(arguments) }.getOrElse {
            deliver(callback, errorMap("invalid_request")); return
        }
        if (pending.size >= maxConcurrentRequests) { deliver(callback, errorMap("worker_busy")); return }
        val extensionId = arguments["extensionId"] as String
        val id = sequence.incrementAndGet()
        val clientRequestId = runCatching { AniyomiRequestPolicy.clientRequestId(arguments) }.getOrElse {
            deliver(callback, errorMap("invalid_request")); return
        } ?: -id
        if (pending.containsKey(clientRequestId)) { deliver(callback, errorMap("invalid_request")); return }
        val cookieJar = cookieJars.getOrPut(extensionId, ::AniyomiEphemeralCookieJar)
        val work = Pending(id, clientRequestId, extensionId, access, request.getString("operation"), callback, cookieJar)
        pending[clientRequestId] = work
        main.postDelayed({ finish(work, errorMap("request_deadline_exceeded")) }, AniyomiPolicy.DEADLINE_MS)
        io.execute {
            try {
                checkAccess(work)
                val (descriptor, file) = store.approved(extensionId)
                checkAccess(work)
                AniyomiExtensionCapabilityPolicy.rejection(
                    operation = work.operation,
                    requiresLocalProxy = descriptor.getBoolean(AniyomiApkStore.LOCAL_PROXY_IDENTITY_FIELD),
                )?.let { rejection ->
                    finish(work, errorMap("extension_local_proxy_required", stage = rejection.stage, cause = "unsupported_capability"))
                    return@execute
                }
                main.post {
                    if (!isCurrent(work)) return@post
                    val connection = object : ServiceConnection {
                        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
                            if (service == null || !isCurrent(work)) {
                                finish(work, errorMap("worker_unavailable")); return
                            }
                            work.remote = service
                            val death = IBinder.DeathRecipient {
                                // A oneway result may be queued immediately before process exit.
                                main.postDelayed({ finish(work, errorMap("worker_terminated")) }, 100)
                            }
                            work.death = death
                            runCatching { service.linkToDeath(death, 0) }.onFailure {
                                finish(work, errorMap("worker_unavailable")); return
                            }
                            io.execute {
                                try {
                                    checkAccess(work)
                                    val hello = AniyomiWire.call(service, AniyomiWire.HELLO) {}
                                    try {
                                        val uid = hello.readInt()
                                        check(uid != Process.myUid() && uid % 100_000 in 90_000..99_999 && hello.readInt() == 1) {
                                            "worker_not_isolated"
                                        }
                                        work.workerUid = uid
                                    } finally { hello.recycle() }
                                    checkAccess(work)
                                    ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { apk ->
                                        val reply = AniyomiWire.call(service, AniyomiWire.EXECUTE) { data ->
                                            data.writeLong(work.id)
                                            data.writeLong(work.deadline)
                                            data.writeString(descriptor.toString())
                                            data.writeString(request.toString())
                                            data.writeStrongBinder(work.callbackBinder)
                                            apk.writeToParcel(data, 0)
                                        }
                                        reply.recycle()
                                    }
                                } catch (_: Exception) { finish(work, errorMap("worker_start_failed")) }
                            }
                        }
                        override fun onServiceDisconnected(name: ComponentName?) { finish(work, errorMap("worker_disconnected")) }
                        override fun onBindingDied(name: ComponentName?) { finish(work, errorMap("worker_binding_died")) }
                        override fun onNullBinding(name: ComponentName?) { finish(work, errorMap("worker_unavailable")) }
                    }
                    work.connection = connection
                    try {
                        checkAccess(work)
                        val intent = Intent(application, AniyomiIsolatedService::class.java)
                        work.bound = if (Build.VERSION.SDK_INT >= 29) {
                            application.bindIsolatedService(intent, Context.BIND_AUTO_CREATE, "$instancePrefix${work.id}",
                                application.mainExecutor, connection)
                        } else {
                            application.bindService(intent, connection, Context.BIND_AUTO_CREATE)
                        }
                        if (!work.bound) finish(work, errorMap("worker_bind_failed"))
                    } catch (_: Exception) { finish(work, errorMap("worker_bind_failed")) }
                }
            } catch (error: Exception) { finish(work, errorMap(safeError(error, "extension_not_approved_or_changed"))) }
        }
    }

    /** Fetch one previously granted manga image without disclosing its transport state. */
    @Synchronized fun fetchImage(arguments: Map<*, *>, callback: (Map<String, Any?>) -> Unit) {
        val extensionId = arguments["extensionId"] as? String
        val token = arguments["capability"] as? String
        if (arguments.keys.any { it !in setOf("extensionId", "capability") } ||
            extensionId == null || token == null
        ) {
            deliver(callback, errorMap("image_capability_invalid")); return
        }
        val grant = runCatching {
            requireAvailable()
            imageCapabilities.resolve(extensionId, token).also { lease.check(it.access) }
        }.getOrElse {
            deliver(callback, errorMap("image_capability_invalid")); return
        }
        if (pendingImages.size >= MAX_PENDING_IMAGE_FETCHES) {
            deliver(callback, errorMap("image_busy")); return
        }
        val id = sequence.incrementAndGet()
        val work = PendingImage(id, grant, callback)
        pendingImages[id] = work
        imageIo.execute {
            val result = try {
                checkImageAccess(work)
                val bytes = work.fetcher.fetch(grant)
                checkImageAccess(work)
                mapOf("ok" to true, "data" to bytes)
            } catch (error: Throwable) {
                errorMap(safeImageError(error))
            }
            finishImage(work, result)
        }
    }

    /** Also called on developer-mode disable. APK cache is preserved, but execution consent is removed. */
    fun revoke(extensionId: String? = null) {
        lease.revoke()
        pendingSnapshot().forEach { it.broker.cancel(); finish(it, errorMap("developer_access_revoked")) }
        imageSnapshot().forEach { it.fetcher.cancel(); finishImage(it, errorMap("developer_access_revoked")) }
        synchronized(this) {
            imageCapabilities.clear()
            if (extensionId == null) {
                cookieJars.values.forEach(AniyomiEphemeralCookieJar::clear)
                cookieJars.clear()
            } else {
                cookieJars.remove(extensionId)?.clear()
            }
        }
        store.revoke(extensionId)
    }

    /** Route dismissal or Dart timeout cancels capabilities without erasing previously approved identities. */
    fun cancelRequests() {
        lease.revoke()
        pendingSnapshot().forEach { it.broker.cancel(); finish(it, errorMap("request_cancelled")) }
        imageSnapshot().forEach { it.fetcher.cancel(); finishImage(it, errorMap("request_cancelled")) }
        imageCapabilities.clear()
        store.clearInspections()
    }

    /** Developer-mode opt-out keeps approved APK identities but drops all ephemeral session state. */
    fun disable() {
        cancelRequests()
        synchronized(this) {
            cookieJars.values.forEach(AniyomiEphemeralCookieJar::clear)
            cookieJars.clear()
        }
    }

    /** Cancels one Dart-owned request without revoking concurrent worker leases. */
    fun cancelRequest(clientRequestId: Long) {
        val work = synchronized(this) { pending[clientRequestId] } ?: return
        work.broker.cancel()
        finish(work, errorMap("request_cancelled"))
    }

    fun close() {
        closed = true
        lease.revoke()
        pendingSnapshot().forEach { it.broker.cancel(); finish(it, errorMap("host_closed")) }
        imageSnapshot().forEach { it.fetcher.cancel(); finishImage(it, errorMap("host_closed")) }
        synchronized(this) {
            imageCapabilities.clear()
            cookieJars.values.forEach(AniyomiEphemeralCookieJar::clear)
            cookieJars.clear()
        }
        io.shutdownNow()
        imageIo.shutdownNow()
    }

    private fun requireAvailable() {
        check(!closed && Build.VERSION.SDK_INT >= 26 && isDeveloperModeEnabled())
    }

    private fun checkAccess(work: Pending) {
        lease.check(work.access)
        check(isCurrent(work) && SystemClock.elapsedRealtime() < work.deadline) { "request_cancelled_or_expired" }
    }

    private fun checkImageAccess(work: PendingImage) {
        lease.check(work.grant.access)
        check(isCurrent(work) && SystemClock.elapsedRealtime() < work.deadline) {
            "image_request_cancelled_or_expired"
        }
    }

    private fun isCurrent(work: Pending): Boolean = !closed && synchronized(this) {
        pending[work.clientRequestId] === work
    }

    private fun isCurrent(work: PendingImage): Boolean = !closed && synchronized(this) {
        pendingImages[work.id] === work
    }

    private fun finish(work: Pending, result: Map<String, Any?>) {
        synchronized(this) {
            if (pending[work.clientRequestId] !== work) return
            pending.remove(work.clientRequestId)
        }
        work.broker.cancel()
        val teardown = Runnable {
            work.remote?.let { remote ->
                work.death?.let { runCatching { remote.unlinkToDeath(it, 0) } }
                val data = Parcel.obtain()
                try {
                    data.writeInterfaceToken(AniyomiWire.DESCRIPTOR)
                    remote.transact(AniyomiWire.CANCEL, data, null, IBinder.FLAG_ONEWAY)
                } catch (_: Exception) { /* Already dead is the desired teardown state. */ }
                finally { data.recycle() }
            }
            if (work.bound) work.connection?.let { runCatching { application.unbindService(it) } }
            val final = if (result["ok"] == true && runCatching { lease.check(work.access) }.isFailure) {
                errorMap("developer_access_revoked")
            } else result
            work.callback(final)
        }
        if (Looper.myLooper() == main.looper) teardown.run() else main.post(teardown)
    }

    @Synchronized private fun pendingSnapshot(): List<Pending> = pending.values.toList()
    @Synchronized private fun imageSnapshot(): List<PendingImage> = pendingImages.values.toList()

    private fun finishImage(work: PendingImage, result: Map<String, Any?>) {
        synchronized(this) {
            if (pendingImages[work.id] !== work) return
            pendingImages.remove(work.id)
        }
        work.fetcher.cancel()
        val delivery = Runnable {
            val final = if (result["ok"] == true && runCatching {
                    lease.check(work.grant.access)
                    check(SystemClock.elapsedRealtime() < work.deadline)
                }.isFailure
            ) errorMap("developer_access_revoked") else result
            work.callback(final)
        }
        if (Looper.myLooper() == main.looper) delivery.run() else main.post(delivery)
    }

    private inner class PendingImage(
        val id: Long,
        val grant: AniyomiImageCapabilityStore.Grant,
        val callback: (Map<String, Any?>) -> Unit,
    ) {
        val deadline = minOf(
            grant.expiresAt,
            SystemClock.elapsedRealtime() + IMAGE_FETCH_DEADLINE_MS,
        )
        val fetcher = AniyomiImageFetcher(deadline) { checkImageAccess(this) }
    }

    private inner class Pending(
        val id: Long,
        val clientRequestId: Long,
        val extensionId: String,
        val access: Long,
        val operation: String,
        val callback: (Map<String, Any?>) -> Unit,
        cookieJar: AniyomiEphemeralCookieJar,
    ) {
        val deadline = SystemClock.elapsedRealtime() + AniyomiPolicy.DEADLINE_MS
        @Volatile var remote: IBinder? = null
        @Volatile var workerUid = -1
        var connection: ServiceConnection? = null
        var death: IBinder.DeathRecipient? = null
        var bound = false
        val broker = AniyomiHttpBroker(deadline, { checkAccess(this) }, application.cacheDir, cookieJar)
        val callbackBinder = object : Binder() {
            override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
                require(workerUid >= 0 && Binder.getCallingUid() == workerUid) { "worker_uid_required" }
                AniyomiWire.checkParcel(data, AniyomiWire.CALLBACK_DESCRIPTOR,
                    if (code == AniyomiWire.COMPLETE) AniyomiPolicy.MAX_REPLY_BYTES else AniyomiPolicy.MAX_REQUEST_BYTES)
                require(data.readLong() == id)
                return when (code) {
                    AniyomiWire.COMPLETE -> {
                        val response = AniyomiWire.readJson(data, AniyomiPolicy.MAX_REPLY_BYTES)
                        require(data.dataAvail() == 0)
                        try {
                            try {
                                checkAccess(this@Pending)
                            } catch (_: Exception) {
                                finish(this@Pending, errorMap("developer_access_revoked"))
                                return true
                            }
                            val checked = if (response.optBoolean("ok", false)) {
                                val sanitized = try {
                                    val raw = response.getJSONObject("data")
                                    AniyomiResultPolicy.sanitize(
                                        operation,
                                        jsonMap(raw),
                                        privateMangaImages = extensionId.startsWith("aniyomi:manga:"),
                                    )
                                } catch (error: Exception) {
                                    // Preserve only a fixed boundary/stage marker. Provider
                                    // values, URLs and exception text never cross to Flutter.
                                    finish(
                                        this@Pending,
                                        errorMap(
                                            "invalid_or_revoked_extension_result",
                                            stage = "result_validation",
                                            cause = if (error is SecurityException) "security_denied" else "invalid_input",
                                        ),
                                    )
                                    return true
                                }
                                mapOf(
                                    "ok" to true,
                                    "data" to broker.withDiagnostics(imageCapabilities.protectResult(
                                        operation = operation,
                                        result = sanitized,
                                        extensionId = extensionId,
                                        access = access,
                                        cookieJar = cookieJar,
                                    )),
                                )
                            } else {
                                AniyomiFailurePolicy.sanitize(response.optString("error"),
                                    response.optString("stage"), response.optString("cause"),
                                    response.optString("broker_failure"), response.optInt("broker_redirect_count", -1),
                                    response.optString("broker_response_size_bucket"), response.optString("broker_status_class"),
                                    response.optString("broker_reason"))
                            }
                            finish(this@Pending, checked)
                        } catch (_: Exception) { finish(this@Pending, errorMap("invalid_or_revoked_extension_result")) }
                        true
                    }
                    AniyomiWire.HTTP -> {
                        val response = try {
                            checkAccess(this@Pending)
                            val input = AniyomiWire.readJson(data, AniyomiPolicy.MAX_REQUEST_BYTES)
                            require(data.dataAvail() == 0)
                            broker.execute(input)
                        } catch (error: Exception) { AniyomiHttpReply(broker.failure(error)) }
                        response.use { if (reply != null) it.writeTo(reply) }
                        true
                    }
                    else -> false
                }
            }
        }
    }

    private fun deliver(callback: (Map<String, Any?>) -> Unit, value: Map<String, Any?>) { main.post { callback(value) } }

    private fun successMap(value: JSONObject): Map<String, Any?> = mapOf("ok" to true, "data" to jsonMap(value))
    private fun errorMap(
        code: String,
        stage: String? = null,
        cause: String? = null,
    ): Map<String, Any?> = mutableMapOf<String, Any?>(
        "ok" to false,
        "error" to code,
    ).apply {
        stage?.let { put("stage", it) }
        cause?.let { put("cause", it) }
    }
    private fun safeError(error: Throwable, fallback: String): String {
        val allowed = setOf("android_26_required", "invalid_import_file", "extension_limit_reached", "unsupported_anime_api",
            "unsupported_manga_api", "apk_signature_invalid_or_multisigner", "extension_feature_missing", "extension_class_invalid",
            "native_code_unsupported", "unsupported_dex_layout", "inspection_expired", "identity_changed",
            "signer_change_requires_revocation", "version_downgrade", "extension_not_approved", "approved_identity_changed",
            "snapshot_unavailable", "developer_access_revoked")
        return error.message?.takeIf { it in allowed } ?: fallback
    }

    private fun safeImageError(error: Throwable): String {
        val code = error.message
        return if (code in setOf(
                "image_capability_invalid", "image_busy", "image_response_too_large",
                "image_redirect_limit", "image_http_failure", "image_empty",
                "image_not_supported", "image_malformed", "image_dimensions_exceeded",
                "private_network_blocked", "private_host_blocked", "public_https_required",
                "https_port_not_allowed", "invalid_https_url", "invalid_https_host",
                "image_request_cancelled_or_expired",
            )) code!! else "image_fetch_failed"
    }

    private fun jsonMap(json: JSONObject): Map<String, Any?> = json.keys().asSequence().associateWith { key ->
        jsonValue(json.get(key), 0)
    }
    private fun jsonValue(value: Any?, depth: Int): Any? {
        require(depth <= 16) { "result_nesting_limit" }
        return when (value) {
            JSONObject.NULL, null -> null
            is JSONObject -> value.keys().asSequence().associateWith { jsonValue(value.get(it), depth + 1) }
            is JSONArray -> (0 until value.length()).map { jsonValue(value.get(it), depth + 1) }
            is String, is Boolean, is Int, is Long -> value
            is Number -> value.toDouble().also { require(it.isFinite()) }
            else -> throw IllegalArgumentException("unsupported_result_value")
        }
    }

    internal companion object {
        private const val MAX_CONCURRENT_WORKERS = 3
        private const val MAX_CONCURRENT_IMAGE_FETCHES = 3
        private const val MAX_PENDING_IMAGE_FETCHES = 12
        private const val IMAGE_FETCH_DEADLINE_MS = 30_000L
        fun workerCapacity(apiLevel: Int): Int = if (apiLevel >= 29) MAX_CONCURRENT_WORKERS else 1
    }
}
