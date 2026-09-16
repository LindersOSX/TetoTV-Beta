package dev.animetv.anime_tv.aniyomi

import android.os.Parcel
import android.os.ParcelFileDescriptor
import android.util.Base64
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONObject

/** Only bounded metadata and a read-only response-body capability enter Binder. */
internal class AniyomiHttpReply(
    val metadata: JSONObject,
    private val body: AniyomiHttpBodyFile? = null,
    private val onClose: () -> Unit = {},
) : Closeable {
    fun writeTo(reply: Parcel) {
        val text = AniyomiPolicy.boundedText(metadata.toString(), AniyomiPolicy.MAX_HTTP_REPLY_BYTES)
        reply.writeNoException()
        reply.writeString(text)
        reply.writeInt(if (body == null) 0 else 1)
        // The Parcel owns a duplicate after this call; the host closes its
        // handle on return. The disposable worker closes its copy after read.
        body?.descriptor?.writeToParcel(reply, 0)
    }

    override fun close() {
        try { body?.close() } finally { onClose() }
    }

    companion object {
        /** The large base64 DTO exists only inside the disposable worker. */
        fun readFrom(reply: Parcel, checkAllowed: () -> Unit): JSONObject {
            require(reply.dataSize() <= AniyomiPolicy.MAX_HTTP_REPLY_BYTES * 2 + 1024)
            val metadata = AniyomiWire.readJson(reply, AniyomiPolicy.MAX_HTTP_REPLY_BYTES)
            require(!metadata.has("bodyBase64"))
            require(reply.dataAvail() >= 4)
            val hasBody = reply.readInt()
            require(hasBody == 0 || hasBody == 1)
            val descriptor = if (hasBody == 1) ParcelFileDescriptor.CREATOR.createFromParcel(reply) else null
            descriptor.use { body ->
                require(reply.dataAvail() == 0)
                if (metadata.has("error")) {
                    require(body == null && !metadata.has("bodyLength"))
                } else {
                    require(body != null)
                    val lengthValue = metadata.get("bodyLength")
                    require(lengthValue is Int && lengthValue in 0..AniyomiPolicy.MAX_HTTP_BYTES)
                    val expectedLength = lengthValue
                    // A regular file of the advertised exact size is required;
                    // pipes/sockets/streams with unbounded blocking are rejected.
                    require(body.statSize == expectedLength.toLong())
                    val bytes = ByteArrayOutputStream(expectedLength)
                    val actualLength = ParcelFileDescriptor.AutoCloseInputStream(body).use { input ->
                        AniyomiHttpBodyPolicy.copy(
                            input, bytes, expectedLength.toLong(), expectedLength, checkAllowed,
                        )
                    }
                    require(actualLength == expectedLength)
                    checkAllowed()
                    metadata.remove("bodyLength")
                    metadata.put("bodyBase64", Base64.encodeToString(bytes.toByteArray(), Base64.NO_WRAP))
                }
            }
            return metadata
        }
    }
}

/**
 * Unlinked before any provider data is written. There is no reusable path,
 * directory handle, writable worker FD, or authority over other app files.
 */
internal class AniyomiHttpBodyFile private constructor(
    val output: FileOutputStream,
    val descriptor: ParcelFileDescriptor,
) : Closeable {
    private val closed = AtomicBoolean(false)

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        try { output.close() } finally { descriptor.close() }
    }

    companion object {
        fun create(cacheDirectory: File): AniyomiHttpBodyFile {
            val file = File.createTempFile("aniyomi-http-", ".body", cacheDirectory)
            var output: FileOutputStream? = null
            var descriptor: ParcelFileDescriptor? = null
            try {
                output = FileOutputStream(file)
                descriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
                if (!file.delete()) throw IOException("http_body_unlink_failed")
                return AniyomiHttpBodyFile(output, descriptor)
            } catch (error: Throwable) {
                runCatching { output?.close() }
                runCatching { descriptor?.close() }
                throw error
            } finally {
                // Only this uniquely created, initially empty file is touched.
                if (file.exists()) file.delete()
            }
        }
    }
}
