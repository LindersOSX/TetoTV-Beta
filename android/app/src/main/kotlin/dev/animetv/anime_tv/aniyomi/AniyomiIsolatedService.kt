package dev.animetv.anime_tv.aniyomi

import android.app.Service
import android.content.Intent
import android.os.Binder
import android.os.Build
import android.os.IBinder
import android.os.Parcel
import android.os.ParcelFileDescriptor
import android.os.Process
import android.os.SystemClock
import dalvik.system.InMemoryDexClassLoader
import dev.animetv.anime_tv.AnonymousCrashStore
import dev.animetv.anime_tv.aniyomi.compat.AniyomiBrokerInvalidResponse
import dev.animetv.anime_tv.aniyomi.compat.AniyomiBrokerDiagnosticContext
import dev.animetv.anime_tv.aniyomi.compat.AniyomiBrokerNetworkFailure
import dev.animetv.anime_tv.aniyomi.compat.AniyomiBrokerPolicyDenied
import dev.animetv.anime_tv.aniyomi.compat.AniyomiBrokerUnsupportedCapability
import dev.animetv.anime_tv.aniyomi.compat.AniyomiCompatRuntime
import dev.animetv.anime_tv.aniyomi.compat.AniyomiRuntimeFailure
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.zip.ZipInputStream
import org.json.JSONObject

/** One invocation per isolated process. Never runs as a normal same-UID remote service. */
class AniyomiIsolatedService : Service() {
    private val used = AtomicBoolean(false)
    private val executor = Executors.newSingleThreadExecutor()
    private val watchdog = Executors.newSingleThreadScheduledExecutor()
    private val lifecycle = AniyomiWorkerLifecycle()
    private val fatalReported = AtomicBoolean(false)
    @Volatile private var owner: IBinder? = null
    @Volatile private var activeRequestId = -1L
    @Volatile private var activeOperation = ""
    private val ownerDeath = IBinder.DeathRecipient { terminate() }

    private val endpoint = object : Binder() {
        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            if (code == INTERFACE_TRANSACTION) {
                reply?.writeString(AniyomiWire.DESCRIPTOR)
                return true
            }
            require(Binder.getCallingUid() == applicationInfo.uid) { "host_uid_required" }
            check(Process.myUid() != applicationInfo.uid) { "isolated_process_required" }
            AniyomiWire.checkParcel(data, AniyomiWire.DESCRIPTOR)
            when (code) {
                AniyomiWire.HELLO -> {
                    require(data.dataAvail() == 0)
                    reply?.writeNoException()
                    reply?.writeInt(Process.myUid())
                    reply?.writeInt(1)
                    return true
                }
                AniyomiWire.CANCEL -> {
                    terminate()
                    return true
                }
                AniyomiWire.EXECUTE -> {
                    check(Build.VERSION.SDK_INT >= 26 && used.compareAndSet(false, true)) { "worker_unavailable" }
                    val requestId = data.readLong()
                    val deadline = data.readLong()
                    val now = SystemClock.elapsedRealtime()
                    require(deadline > now && deadline - now <= AniyomiPolicy.DEADLINE_MS)
                    val descriptor = AniyomiWire.readJson(data, 8192)
                    val request = AniyomiWire.readJson(data, AniyomiPolicy.MAX_REQUEST_BYTES)
                    val callback = data.readStrongBinder() ?: throw IllegalArgumentException("callback_required")
                    val apk = ParcelFileDescriptor.CREATOR.createFromParcel(data)
                    if (data.dataAvail() != 0) { apk.close(); throw IllegalArgumentException("unexpected_payload") }
                    owner = callback
                    activeRequestId = requestId
                    activeOperation = request.optString("operation")
                    callback.linkToDeath(ownerDeath, 0)
                    lifecycle.scheduleTermination(watchdog, deadline - now, ::terminate)
                    executor.execute {
                        val response = try {
                            apk.use { handle ->
                                val loader = loadVerifiedDex(handle, descriptor.getString("apkSha256"))
                                val result = AniyomiCompatRuntime.execute(loader, descriptor, request) { networkRequest ->
                                    check(SystemClock.elapsedRealtime() < deadline) { "deadline_exceeded" }
                                    broker(callback, requestId, deadline, networkRequest)
                                }
                                JSONObject().put("ok", true).put("data", result)
                            }
                        } catch (error: Throwable) {
                            if (error is VirtualMachineError || error is ThreadDeath) throw error
                            val failure = AniyomiRuntimeFailure.describe(error, "dex_load")
                            AniyomiWire.error(failure.errorCode).put("stage", failure.stage).put("cause", failure.category).apply {
                                failure.brokerFailure?.let { put("broker_failure", it) }
                                failure.brokerReason?.let { put("broker_reason", it) }
                                failure.brokerRedirectCount?.let { put("broker_redirect_count", it) }
                                failure.brokerResponseSizeBucket?.let { put("broker_response_size_bucket", it) }
                                failure.brokerStatusClass?.let { put("broker_status_class", it) }
                            }
                        }
                        val payload = runCatching {
                            AniyomiPolicy.boundedText(response.toString(), AniyomiPolicy.MAX_REPLY_BYTES)
                        }.getOrElse { AniyomiWire.error("extension_result_too_large").toString() }
                        val resultParcel = Parcel.obtain()
                        try {
                            resultParcel.writeInterfaceToken(AniyomiWire.CALLBACK_DESCRIPTOR)
                            resultParcel.writeLong(requestId)
                            resultParcel.writeString(payload)
                            callback.transact(AniyomiWire.COMPLETE, resultParcel, null, IBinder.FLAG_ONEWAY)
                        } catch (_: Exception) {
                            // Host may have revoked access while the request was running.
                        } finally {
                            resultParcel.recycle()
                            // Give a successful oneway result a bounded delivery window, then discard all provider state.
                            lifecycle.scheduleTermination(watchdog, 500, ::terminate)
                        }
                    }
                    reply?.writeNoException()
                    return true
                }
                else -> return false
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        check(Process.myUid() != applicationInfo.uid) { "Manifest must declare isolatedProcess=true" }
        AnonymousCrashStore.recordAniyomiWorkerProcessState(this)
        val platformHandler = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            // Provider-created threads (for example a minified local proxy)
            // can fail outside the request coroutine. Send only the closed
            // failure taxonomy to the trusted host before Android records the
            // process exit; never send the provider stack, URL, or message.
            runCatching { reportFatalWorkerFailure(error) }
            if (platformHandler != null) {
                platformHandler.uncaughtException(thread, error)
            } else {
                Process.killProcess(Process.myPid())
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder = endpoint
    override fun onUnbind(intent: Intent?): Boolean { terminate(); return false }
    override fun onDestroy() { terminate(); super.onDestroy() }

    private fun terminate() {
        if (!lifecycle.beginTermination()) return
        owner?.let { runCatching { it.unlinkToDeath(ownerDeath, 0) } }
        owner = null
        executor.shutdownNow()
        watchdog.shutdownNow()
        Process.killProcess(Process.myPid())
    }

    private fun reportFatalWorkerFailure(error: Throwable) {
        if (!fatalReported.compareAndSet(false, true)) return
        val callback = owner ?: return
        val requestId = activeRequestId.takeIf { it >= 0L } ?: return
        val failure = AniyomiRuntimeFailure.describe(
            error,
            AniyomiWorkerFailureAttribution.stage(activeOperation),
        )
        val payload = AniyomiPolicy.boundedText(
            AniyomiWire.error(failure.errorCode)
                .put("stage", failure.stage)
                .put("cause", failure.category)
                .apply {
                    failure.brokerFailure?.let { put("broker_failure", it) }
                    failure.brokerReason?.let { put("broker_reason", it) }
                    failure.brokerRedirectCount?.let { put("broker_redirect_count", it) }
                    failure.brokerResponseSizeBucket?.let { put("broker_response_size_bucket", it) }
                    failure.brokerStatusClass?.let { put("broker_status_class", it) }
                }
                .toString(),
            AniyomiPolicy.MAX_REPLY_BYTES,
        )
        val result = Parcel.obtain()
        try {
            result.writeInterfaceToken(AniyomiWire.CALLBACK_DESCRIPTOR)
            result.writeLong(requestId)
            result.writeString(payload)
            callback.transact(AniyomiWire.COMPLETE, result, null, IBinder.FLAG_ONEWAY)
        } finally {
            result.recycle()
        }
    }

    private fun broker(callback: IBinder, requestId: Long, deadline: Long, request: JSONObject): JSONObject {
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        try {
            data.writeInterfaceToken(AniyomiWire.CALLBACK_DESCRIPTOR)
            data.writeLong(requestId)
            val requestText = try {
                AniyomiPolicy.boundedText(request.toString(), AniyomiPolicy.MAX_REQUEST_BYTES)
            } catch (_: Exception) {
                throw AniyomiBrokerUnsupportedCapability(AniyomiBrokerDiagnosticContext(reason = "request_envelope"))
            }
            data.writeString(requestText)
            try {
                if (!callback.transact(AniyomiWire.HTTP, data, reply, 0)) {
                    throw AniyomiBrokerNetworkFailure()
                }
                reply.readException()
            } catch (error: AniyomiBrokerNetworkFailure) {
                throw error
            } catch (_: Exception) {
                throw AniyomiBrokerNetworkFailure()
            }
            val result = try {
                AniyomiHttpReply.readFrom(reply) {
                    check(SystemClock.elapsedRealtime() < deadline) { "deadline_exceeded" }
                }
            } catch (_: Exception) {
                throw AniyomiBrokerInvalidResponse()
            }
            // The host intentionally returns only fixed error categories. Convert
            // them to typed causes without exposing a target, response or stack.
            if (result.has("error")) {
                val context = try {
                    val redirects = result.getInt("broker_redirect_count")
                    val size = result.getString("broker_response_size_bucket")
                    val status = result.getString("broker_status_class")
                    require(redirects in 0..3)
                    require(size in AniyomiBrokerDiagnosticContext.SIZE_BUCKETS)
                    require(status in AniyomiBrokerDiagnosticContext.STATUS_CLASSES)
                    AniyomiBrokerDiagnosticContext(redirects, size, status, result.optString("broker_reason", "none"))
                } catch (_: Exception) {
                    throw AniyomiBrokerInvalidResponse()
                }
                throw when (result.optString("error")) {
                    AniyomiBrokerPolicyDenied.CODE -> AniyomiBrokerPolicyDenied(context)
                    AniyomiBrokerNetworkFailure.CODE -> AniyomiBrokerNetworkFailure(context)
                    AniyomiBrokerUnsupportedCapability.CODE -> AniyomiBrokerUnsupportedCapability(context)
                    AniyomiBrokerInvalidResponse.CODE -> AniyomiBrokerInvalidResponse(context)
                    else -> AniyomiBrokerInvalidResponse(context)
                }
            }
            return result
        } finally { data.recycle(); reply.recycle() }
    }

    private fun loadVerifiedDex(apk: ParcelFileDescriptor, expectedHash: String): ClassLoader {
        check(Build.VERSION.SDK_INT >= 26)
        require(apk.statSize in 1..AniyomiPolicy.MAX_APK_BYTES.toLong()) { "apk_size_invalid" }
        val bytes = ParcelFileDescriptor.AutoCloseInputStream(ParcelFileDescriptor.dup(apk.fileDescriptor)).use { input ->
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(32 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                require(output.size() + count <= AniyomiPolicy.MAX_APK_BYTES)
                output.write(buffer, 0, count)
            }
            output.toByteArray()
        }
        val actualHash = MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it.toInt() and 255) }
        require(actualHash == expectedHash) { "worker_apk_integrity_failed" }
        val dex = sortedMapOf<Int, ByteBuffer>()
        val resources = AniyomiApkResources()
        var total = 0
        ZipInputStream(bytes.inputStream()).use { zip ->
            var count = 0
            while (true) {
                val entry = zip.nextEntry ?: break
                require(++count <= 4096)
                require(!entry.name.startsWith("lib/") && !entry.name.endsWith(".so"))
                if (!entry.isDirectory && AniyomiApkResources.validName(entry.name)) {
                    resources.readEntry(entry.name, zip)
                    continue
                }
                val match = Regex("classes([2-9][0-9]*)?\\.dex").matchEntire(entry.name) ?: continue
                val index = match.groupValues[1].toIntOrNull() ?: 1
                require(dex.size < 8 && index !in dex)
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(32 * 1024)
                while (true) {
                    val read = zip.read(buffer)
                    if (read < 0) break
                    total += read
                    require(total <= AniyomiPolicy.MAX_DEX_BYTES)
                    output.write(buffer, 0, read)
                }
                // Android's loader calls array() on non-direct buffers, which rejects
                // read-only heap buffers. Direct read-only buffers keep bytes immutable.
                val dexBytes = output.toByteArray()
                dex[index] = ByteBuffer.allocateDirect(dexBytes.size).apply {
                    put(dexBytes)
                    flip()
                }.asReadOnlyBuffer()
            }
        }
        require(dex.isNotEmpty()) { "dex_missing" }
        val parent = AniyomiExtensionParentClassLoader(
            checkNotNull(AniyomiCompatRuntime::class.java.classLoader),
            resources,
        )
        return if (Build.VERSION.SDK_INT >= 27) {
            InMemoryDexClassLoader(dex.values.toTypedArray(), parent)
        } else {
            require(dex.size == 1) { "multidex_requires_android_27" }
            InMemoryDexClassLoader(dex.values.single(), parent)
        }
    }
}
