package dev.animetv.anime_tv.aniyomi

import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class AniyomiHttpBodyPolicyTest {
    @Test fun `HTML and JSON above old 256KiB and 1MiB limits arrive intact`() {
        for (size in listOf(256 * 1024 + 1, 1024 * 1024 + 1, AniyomiPolicy.MAX_HTTP_BYTES)) {
            val original = ByteArray(size) { (it % 251).toByte() }
            for (declaredLength in listOf(-1L, size.toLong())) {
                val output = ByteArrayOutputStream()
                val result = AniyomiHttpBodyPolicy.copy(
                    original.inputStream(), output, declaredLength, checkAllowed = {},
                )
                assertEquals(size, result)
                assertArrayEquals(original, output.toByteArray())
            }
        }
    }

    @Test fun `advertised oversized bodies fail before reading a byte`() {
        val reads = AtomicInteger()
        val input = object : InputStream() {
            override fun read(): Int { reads.incrementAndGet(); return 1 }
        }
        val failure = assertThrows(IllegalArgumentException::class.java) {
            AniyomiHttpBodyPolicy.copy(
                input, ByteArrayOutputStream(), AniyomiPolicy.MAX_HTTP_BYTES + 1L, checkAllowed = {},
            )
        }
        assertEquals("http_response_too_large", failure.message)
        assertEquals(0, reads.get())
    }

    @Test fun `unknown and dishonest lengths cannot exceed decoded byte budget`() {
        for (declaredLength in listOf(-1L, 10L)) {
            val output = ByteArrayOutputStream()
            val original = ByteArray(AniyomiPolicy.MAX_HTTP_BYTES + 100) { 1 }
            val input = original.inputStream()
            var observed = 0L
            val failure = assertThrows(IllegalArgumentException::class.java) {
                AniyomiHttpBodyPolicy.copy(
                    input, output, declaredLength, checkAllowed = {}, observeSize = { observed = it },
                )
            }
            assertEquals("http_response_too_large", failure.message)
            assertEquals(AniyomiPolicy.MAX_HTTP_BYTES, output.size())
            assertEquals(AniyomiPolicy.MAX_HTTP_BYTES + 1L, observed)
            assertEquals(99, input.available())
        }
    }

    @Test fun `cancellation during a read stops before the bytes are written`() {
        var cancelled = false
        val output = ByteArrayOutputStream()
        val input = object : InputStream() {
            override fun read(): Int = error("bulk read expected")
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                buffer[offset] = 7
                cancelled = true
                return 1
            }
        }
        assertThrows(IllegalStateException::class.java) {
            AniyomiHttpBodyPolicy.copy(input, output, -1, checkAllowed = { check(!cancelled) })
        }
        assertEquals(0, output.size())
    }

    @Test fun `empty bodies and final actual diagnostic size are preserved`() {
        val observed = ArrayList<Long>()
        val size = AniyomiHttpBodyPolicy.copy(
            ByteArray(0).inputStream(), ByteArrayOutputStream(), -1,
            checkAllowed = {}, observeSize = observed::add,
        )
        assertEquals(0, size)
        assertEquals(listOf(-1L, 0L), observed)
    }

    @Test fun `parallel bodies do not wait behind a stalled sibling`() {
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(2)
        val slowInput = object : InputStream() {
            override fun read(): Int {
                started.countDown()
                check(release.await(5, TimeUnit.SECONDS))
                return -1
            }
        }
        try {
            val slow = executor.submit<Int> {
                AniyomiHttpBodyPolicy.copy(slowInput, ByteArrayOutputStream(), -1, checkAllowed = {})
            }
            assertTrue(started.await(2, TimeUnit.SECONDS))
            val fast = executor.submit<Int> {
                AniyomiHttpBodyPolicy.copy(ByteArray(300_000).inputStream(), ByteArrayOutputStream(), -1, checkAllowed = {})
            }
            assertEquals(300_000, fast.get(2, TimeUnit.SECONDS))
            release.countDown()
            assertEquals(0, slow.get(2, TimeUnit.SECONDS))
        } finally {
            release.countDown()
            executor.shutdownNow()
        }
    }
}
