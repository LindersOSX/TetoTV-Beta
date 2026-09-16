package dev.animetv.anime_tv.aniyomi

import android.content.Context
import android.content.ComponentName
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import android.os.Parcel
import android.os.Process
import android.system.Os
import android.system.OsConstants
import android.util.Base64
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONObject

/** Native Parcel/FD regression, invoked by the existing isolation test runner. */
internal object AniyomiHttpReplyInstrumentation {
    fun run(context: Context, testContext: Context) {
        checkRemoteBinder(context, testContext)
        val cache = context.cacheDir
        fun bodyPaths() = cache.list()?.filter { it.startsWith("aniyomi-http-") && it.endsWith(".body") }?.toSet().orEmpty()
        val existing = bodyPaths()
        for (size in listOf(0, 256 * 1024 + 1, 1024 * 1024 + 1, AniyomiPolicy.MAX_HTTP_BYTES)) {
            val original = ByteArray(size) { (it % 251).toByte() }
            val parcel = Parcel.obtain()
            try {
                val body = AniyomiHttpBodyFile.create(cache)
                body.use {
                    // No response data ever has a filename; only the new empty
                    // file briefly existed before both handles were established.
                    check(bodyPaths() == existing)
                    check(Os.fcntlInt(body.descriptor.fileDescriptor, OsConstants.F_GETFL, 0) and
                        OsConstants.O_ACCMODE == OsConstants.O_RDONLY)
                    body.output.write(original)
                    body.output.close()
                    check(runCatching { Os.write(body.descriptor.fileDescriptor, byteArrayOf(1), 0, 1) }.isFailure)
                    AniyomiHttpReply(metadata(size), body).use { it.writeTo(parcel) }
                }
                // Closing the sender does not invalidate the Parcel-owned copy.
                check(parcel.dataSize() < 1024)
                parcel.setDataPosition(0)
                parcel.readException()
                val result = AniyomiHttpReply.readFrom(parcel) {}
                check(original.contentEquals(Base64.decode(result.getString("bodyBase64"), Base64.DEFAULT)))
                check(result.getJSONObject("headers").getString("Content-Length") == size.toString())
                check(!result.has("bodyLength"))
            } finally { parcel.recycle() }
        }
        // Mismatched lengths and post-read cancellation fail closed, while all
        // sender/receiver descriptors are closed on their failure paths.
        for (advertised in listOf(0, 2, AniyomiPolicy.MAX_HTTP_BYTES + 1)) {
            val parcel = Parcel.obtain()
            try {
                val body = AniyomiHttpBodyFile.create(cache)
                body.output.write(1)
                body.output.close()
                AniyomiHttpReply(metadata(advertised), body).use { it.writeTo(parcel) }
                parcel.setDataPosition(0)
                parcel.readException()
                check(runCatching { AniyomiHttpReply.readFrom(parcel) {} }.isFailure)
            } finally { parcel.recycle() }
        }
        val cancelled = Parcel.obtain()
        try {
            val body = AniyomiHttpBodyFile.create(cache)
            body.output.write(1)
            body.output.close()
            AniyomiHttpReply(metadata(1), body).use { it.writeTo(cancelled) }
            cancelled.setDataPosition(0)
            cancelled.readException()
            check(runCatching { AniyomiHttpReply.readFrom(cancelled) { error("deadline_exceeded") } }.isFailure)
        } finally { cancelled.recycle() }
        for (trailing in listOf(false, true)) {
            val malformed = Parcel.obtain()
            try {
                AniyomiHttpReply(metadata(0)).use { it.writeTo(malformed) }
                if (trailing) malformed.writeInt(123)
                malformed.setDataPosition(0)
                malformed.readException()
                check(runCatching { AniyomiHttpReply.readFrom(malformed) {} }.isFailure)
            } finally { malformed.recycle() }
        }
        val failure = Parcel.obtain()
        try {
            AniyomiHttpReply(AniyomiWire.error("http_broker_network")).use { it.writeTo(failure) }
            failure.setDataPosition(0)
            failure.readException()
            check(AniyomiHttpReply.readFrom(failure) {}.getString("error") == "http_broker_network")
        } finally { failure.recycle() }
        check(bodyPaths() == existing)
    }

    private fun checkRemoteBinder(context: Context, testContext: Context) {
        val ready = CountDownLatch(1)
        val remote = AtomicReference<IBinder>()
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
                remote.set(binder)
                ready.countDown()
            }
            override fun onServiceDisconnected(name: ComponentName?) = Unit
        }
        val intent = Intent().setClassName(testContext.packageName, AniyomiHttpReplyTestService::class.java.name)
        check(context.bindService(intent, connection, Context.BIND_AUTO_CREATE))
        try {
            check(ready.await(10, TimeUnit.SECONDS)) { "HTTP body fixture bind timeout" }
            val original = ByteArray(AniyomiPolicy.MAX_HTTP_BYTES) { (it % 251).toByte() }
            val request = Parcel.obtain()
            val response = Parcel.obtain()
            try {
                val body = AniyomiHttpBodyFile.create(context.cacheDir)
                body.output.write(original)
                body.output.close()
                AniyomiHttpReply(metadata(original.size), body).use { it.writeTo(request) }
                check(request.dataSize() < 1024)
                check(remote.get().transact(IBinder.FIRST_CALL_TRANSACTION, request, response, 0))
                response.readException()
                check(response.readInt() != Process.myUid())
                check(response.readInt() == original.size)
                check(MessageDigest.getInstance("SHA-256").digest(original).contentEquals(response.createByteArray()))
                check(response.dataAvail() == 0)
            } finally {
                request.recycle()
                response.recycle()
            }
        } finally { context.unbindService(connection) }
    }

    private fun metadata(length: Int): JSONObject = JSONObject()
        .put("statusCode", 200).put("url", "https://fixture.invalid/large-response")
        .put("headers", JSONObject().put("Content-Length", length.toString()))
        .put("bodyLength", length).put("broker_redirect_count", 0)
}
