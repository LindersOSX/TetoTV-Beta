package dev.animetv.anime_tv

import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction

/** Size is enforced on bytes before UTF-8 decoding or JSON allocation. */
internal object MangaBackupDocumentCodec {
    const val MAX_BYTES = 12 * 1024 * 1024

    fun readUtf8(input: InputStream): String {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(16 * 1024)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            require(output.size().toLong() + count <= MAX_BYTES) { "Backup exceeds size limit." }
            output.write(buffer, 0, count)
        }
        require(output.size() > 0) { "Backup is empty." }
        return Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(output.toByteArray())).toString()
    }

    fun encoded(value: String): ByteArray {
        require(value.isNotEmpty() && value.length <= MAX_BYTES) { "Invalid backup size." }
        return value.toByteArray(Charsets.UTF_8).also {
            require(it.size <= MAX_BYTES) { "Backup exceeds size limit." }
        }
    }
}
