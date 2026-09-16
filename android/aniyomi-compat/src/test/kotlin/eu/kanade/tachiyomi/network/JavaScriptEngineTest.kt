package eu.kanade.tachiyomi.network

import android.content.Context
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertThrows
import org.junit.Test

class JavaScriptEngineTest {
    @Test fun retainsPublishedContextConstructorAbi() {
        assertNotNull(JavaScriptEngine::class.java.getConstructor(Context::class.java))
    }

    @Test fun acceptsOnlyBoundedQuickJsPrimitiveResults() = runBlocking {
        for (value in listOf<Any?>(null, true, 7, 3.5, "result")) {
            val engine = JavaScriptEngine { value }
            assertEquals(value, engine.evaluate<Any?>("1 + 1"))
        }
    }

    @Test fun rejectsOversizedScriptBeforeStartingNativeEvaluation() {
        val calls = AtomicInteger()
        val engine = JavaScriptEngine { calls.incrementAndGet() }

        val failure = assertThrows(UnsupportedOperationException::class.java) {
            runBlocking { engine.evaluate<Any?>("x".repeat(256 * 1024 + 1)) }
        }
        assertEquals("javascript_input_too_large", failure.message)
        assertEquals(0, calls.get())
    }

    @Test fun boundsUtf8BytesAsWellAsUtf16Characters() {
        val calls = AtomicInteger()
        val engine = JavaScriptEngine { calls.incrementAndGet() }

        assertThrows(UnsupportedOperationException::class.java) {
            runBlocking { engine.evaluate<Any?>("\u20ac".repeat(100_000)) }
        }
        assertEquals(0, calls.get())
    }

    @Test fun rejectsOversizedNonPrimitiveAndNonFiniteResults() {
        val cases = listOf<Any>(
            "x".repeat(256 * 1024 + 1),
            listOf("not", "a", "primitive"),
            Double.NaN,
            Double.POSITIVE_INFINITY,
        )
        for (value in cases) {
            val engine = JavaScriptEngine { value }
            assertThrows(UnsupportedOperationException::class.java) {
                runBlocking { engine.evaluate<Any?>("fixture") }
            }
        }
    }
}
