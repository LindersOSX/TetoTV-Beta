package dev.animetv.anime_tv.aniyomi.compat

import eu.kanade.tachiyomi.network.NetworkHelper
import eu.kanade.tachiyomi.network.awaitSuccess
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.runBlocking
import okhttp3.Dispatcher
import okhttp3.Request
import org.junit.Assert.*
import org.junit.Test

class AniyomiAsyncBrokerFailureTest {
    @Test fun typedBrokerDenialsInAwaitCallsDoNotEscapeTheDispatcherThread() {
        val cases = listOf(
            AniyomiBrokerPolicyDenied() to "security_denied",
            AniyomiBrokerUnsupportedCapability() to "unsupported_capability",
            AniyomiBrokerInvalidResponse() to "invalid_input",
            AniyomiBrokerNetworkFailure() to "io",
        )
        for ((brokerError, category) in cases) {
            val uncaught = CopyOnWriteArrayList<Throwable>()
            val executor = Executors.newSingleThreadExecutor { action ->
                Thread(action, "broker-regression").apply {
                    uncaughtExceptionHandler = Thread.UncaughtExceptionHandler { _, error -> uncaught += error }
                }
            }
            try {
                val client = NetworkHelper(BrokerTransport { throw brokerError }).client.newBuilder()
                    .dispatcher(Dispatcher(executor)).build()
                val thrown = assertThrows(Exception::class.java) {
                    runBlocking {
                        client.newCall(Request.Builder().url("https://fixture.example.test/search").build())
                            .awaitSuccess()
                    }
                }
                val failure = AniyomiRuntimeFailure.describe(thrown, "source_search")
                assertEquals(category, failure.category)
                assertEquals((brokerError as AniyomiBrokerDiagnostic).brokerFailure, failure.brokerFailure)
                assertEquals(0, failure.brokerRedirectCount)
                assertEquals("none", failure.brokerResponseSizeBucket)
                assertEquals("none", failure.brokerStatusClass)
                executor.shutdown()
                assertTrue(executor.awaitTermination(5, TimeUnit.SECONDS))
                assertTrue("Expected broker denial escaped the callback boundary", uncaught.isEmpty())
                assertNull(failure.cause)
            } finally {
                executor.shutdownNow()
            }
        }
    }
}
