package dev.animetv.anime_tv

import java.io.ByteArrayInputStream
import java.io.InputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class MangaBackupDocumentCodecTest {
    @Test
    fun `round trips utf8 without file paths or encoding guesses`() {
        val text = "{\"label\":\"読書\"}"
        assertEquals(text, MangaBackupDocumentCodec.readUtf8(ByteArrayInputStream(MangaBackupDocumentCodec.encoded(text))))
    }

    @Test
    fun `rejects empty invalid utf8 and oversized streams before decoding`() {
        assertThrows(IllegalArgumentException::class.java) {
            MangaBackupDocumentCodec.readUtf8(ByteArrayInputStream(byteArrayOf()))
        }
        assertThrows(java.nio.charset.CharacterCodingException::class.java) {
            MangaBackupDocumentCodec.readUtf8(ByteArrayInputStream(byteArrayOf(0xc3.toByte(), 0x28)))
        }
        var supplied = 0
        val oversized = object : InputStream() {
            override fun read(): Int = 'a'.code
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                val remaining = MangaBackupDocumentCodec.MAX_BYTES + 1 - supplied
                if (remaining <= 0) return -1
                val count = minOf(length, remaining)
                buffer.fill('a'.code.toByte(), offset, offset + count)
                supplied += count
                return count
            }
        }
        assertThrows(IllegalArgumentException::class.java) { MangaBackupDocumentCodec.readUtf8(oversized) }
        assertTrue(supplied <= MangaBackupDocumentCodec.MAX_BYTES + 1)
    }

    @Test
    fun `outbound cap counts utf8 bytes not only characters`() {
        assertThrows(IllegalArgumentException::class.java) {
            MangaBackupDocumentCodec.encoded("読".repeat(MangaBackupDocumentCodec.MAX_BYTES / 3 + 1))
        }
    }
}
