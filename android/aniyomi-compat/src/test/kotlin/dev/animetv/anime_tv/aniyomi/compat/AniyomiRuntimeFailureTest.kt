package dev.animetv.anime_tv.aniyomi.compat

import java.lang.reflect.InvocationTargetException
import java.io.IOException
import java.util.concurrent.TimeoutException
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class AniyomiRuntimeFailureTest {
    @Test fun reflectedConstructorMissingAbiHasFixedCategoryAndStage() {
        val failure = construct(MissingAbiConstructorFixture::class.java)
        assertEquals("source_construct", failure.stage)
        assertEquals("method_missing", failure.category)
        assertEquals("unsupported_extension_abi", failure.errorCode)
        assertFalse(failure.toString().contains("secret"))
        assertNull(failure.cause)
    }

    @Test fun reflectedConstructorCapabilityFailureIsNotMisreportedAsGenericExecution() {
        val failure = construct(UnsupportedConstructorFixture::class.java)
        assertEquals("source_construct", failure.stage)
        assertEquals("unsupported_capability", failure.category)
        assertEquals("unsupported_extension_capability", failure.errorCode)
    }

    @Test fun classLoadingFailureIsDistinctFromConstruction() {
        val failure = assertThrows(AniyomiRuntimeFailure::class.java) {
            execute("missing.generated.fixture.Provider")
        }
        assertEquals("class_load", failure.stage)
        assertEquals("class_missing", failure.category)
    }

    @Test fun nestedInitializationWrappersAreBoundedAndSanitized() {
        val error = InvocationTargetException(ExceptionInInitializerError(NoSuchFieldError("secret")))
        val failure = AniyomiRuntimeFailure.describe(error, "source_construct")
        assertEquals("field_missing", failure.category)
        assertEquals("source_construct:field_missing", failure.message)
    }

    @Test fun existingSanitizedStageIsNotOverwritten() {
        val failure = assertThrows(AniyomiRuntimeFailure::class.java) {
            AniyomiRuntimeFailure.atStage("runtime_setup") {
                AniyomiRuntimeFailure.atStage("source_operation") { throw UnsupportedOperationException("secret") }
            }
        }
        assertEquals("source_operation", failure.stage)
    }

    @Test fun brokerPolicyDenialHasFixedPrivacySafeCause() {
        val failure = AniyomiRuntimeFailure.describe(AniyomiBrokerPolicyDenied(), "source_operation")
        assertEquals("source_operation", failure.stage)
        assertEquals("security_denied", failure.category)
        assertEquals("unsupported_extension_capability", failure.errorCode)
        assertEquals("source_operation:security_denied", failure.message)
        assertFalse(failure.toString().contains("http_broker_denied"))
        assertNull(failure.cause)
    }

    @Test fun brokerTransportCategoriesAreFixedAndDoNotLeakMessages() {
        val cases = listOf(
            AniyomiBrokerNetworkFailure() to "io",
            AniyomiBrokerUnsupportedCapability() to "unsupported_capability",
            AniyomiBrokerInvalidResponse() to "invalid_input",
        )
        for ((error, category) in cases) {
            val failure = AniyomiRuntimeFailure.describe(error, "source_operation")
            assertEquals(category, failure.category)
            assertEquals("source_operation:$category", failure.message)
            assertFalse(failure.toString().contains("http_broker_"))
            assertNull(failure.cause)
        }
    }

    @Test fun hosterTimeoutHasAStableTimeoutCodeWithoutProviderText() {
        val failure = AniyomiRuntimeFailure.describe(
            TimeoutException("secret provider host and URL"),
            "source_videos",
        )
        assertEquals("source_videos", failure.stage)
        assertEquals("timeout", failure.category)
        assertEquals("extension_hoster_timeout", failure.errorCode)
        assertFalse(failure.toString().contains("secret"))
    }

    @Test fun providerCoroutineTimeoutHasTheSameStableTimeoutCode() {
        val timeout = assertThrows(TimeoutCancellationException::class.java) {
            runBlocking {
                withTimeout(10) { delay(1_000) }
            }
        }
        val failure = AniyomiRuntimeFailure.describe(timeout, "source_videos")
        assertEquals("source_videos", failure.stage)
        assertEquals("timeout", failure.category)
        assertEquals("extension_hoster_timeout", failure.errorCode)
    }

    @Test fun brokerTroubleshootingContextIsBoundedAndPreserved() {
        val context = AniyomiBrokerDiagnosticContext(
            redirectCount = 3,
            responseSizeBucket = "128to256k",
            statusClass = "5xx",
        )
        val failure = AniyomiRuntimeFailure.describe(AniyomiBrokerNetworkFailure(context), "source_operation")
        assertEquals("network", failure.brokerFailure)
        assertEquals(3, failure.brokerRedirectCount)
        assertEquals("128to256k", failure.brokerResponseSizeBucket)
        assertEquals("5xx", failure.brokerStatusClass)
        assertThrows(IllegalArgumentException::class.java) {
            AniyomiBrokerDiagnosticContext(4, "secret", "https://secret.example")
        }
    }

    @Test fun awaitIoWrapperPreservesOnlyTypedBrokerDiagnostics() {
        val context = AniyomiBrokerDiagnosticContext(
            redirectCount = 2,
            responseSizeBucket = "64to128k",
            statusClass = "4xx",
        )
        val cases = listOf(
            AniyomiBrokerPolicyDenied(context) to "policy",
            AniyomiBrokerNetworkFailure(context) to "network",
            AniyomiBrokerUnsupportedCapability(context) to "unsupported",
            AniyomiBrokerInvalidResponse(context) to "invalid",
        )
        for ((typed, expectedFailure) in cases) {
            val failure = AniyomiRuntimeFailure.describe(
                IOException("provider-controlled text", typed),
                "source_search",
            )
            assertEquals(expectedFailure, failure.brokerFailure)
            assertEquals(2, failure.brokerRedirectCount)
            assertEquals("64to128k", failure.brokerResponseSizeBucket)
            assertEquals("4xx", failure.brokerStatusClass)
            assertFalse(failure.toString().contains("provider-controlled"))
            assertNull(failure.cause)
        }

        val unrelated = AniyomiRuntimeFailure.describe(
            IOException("provider-controlled text", IOException("nested secret")),
            "source_search",
        )
        assertEquals("io", unrelated.category)
        assertNull(unrelated.brokerFailure)
        assertFalse(unrelated.toString().contains("provider-controlled"))
        assertNull(unrelated.cause)
    }

    @Test fun successfulResponseContextCanBeAttachedWithoutInventingBrokerFailure() {
        val original = AniyomiRuntimeFailure.describe(IllegalStateException("secret"), "source_search")
        val failure = original.withFallbackBrokerContext(
            AniyomiBrokerDiagnosticContext(1, "lt64k", "4xx"),
        )
        assertEquals("source_search", failure.stage)
        assertEquals("execution", failure.category)
        assertNull(failure.brokerFailure)
        assertEquals(1, failure.brokerRedirectCount)
        assertEquals("lt64k", failure.brokerResponseSizeBucket)
        assertEquals("4xx", failure.brokerStatusClass)
        assertFalse(failure.toString().contains("secret"))
    }

    @Test fun asynchronousAwaitWrappersRetainBrokerFailureWithoutAcceptingOtherExceptionChains() {
        val context = AniyomiBrokerDiagnosticContext(1, "lt64k", "4xx")
        val failure = AniyomiRuntimeFailure.describe(
            IOException("private await text", IOException("private transport text", AniyomiBrokerPolicyDenied(context))),
            "source_search",
        )
        assertEquals("security_denied", failure.category)
        assertEquals("policy", failure.brokerFailure)
        assertEquals(1, failure.brokerRedirectCount)
        assertEquals("lt64k", failure.brokerResponseSizeBucket)
        assertEquals("4xx", failure.brokerStatusClass)
        assertNull(failure.cause)
        assertFalse(failure.toString().contains("private"))

        val unrelated = AniyomiRuntimeFailure.describe(
            IOException("outer", IOException("inner", SecurityException("private"))), "source_search",
        )
        assertEquals("io", unrelated.category)
        assertNull(unrelated.brokerFailure)

        val cycle = IOException("cycle")
        val cyclePeer = IOException("peer", cycle)
        cycle.initCause(cyclePeer)
        assertEquals("io", AniyomiRuntimeFailure.describe(cycle, "source_search").category)
    }

    @Test fun linkageSubtypesRemainFixedAbiCodesWithoutExceptionText() {
        val cases = listOf(VerifyError("secret") to "verify_error", IllegalAccessError("secret") to "illegal_access",
            IncompatibleClassChangeError("secret") to "incompatible_class_change", ClassFormatError("secret") to "class_format",
            UnsatisfiedLinkError("secret") to "native_linkage")
        for ((error, category) in cases) {
            val failure = AniyomiRuntimeFailure.describe(InvocationTargetException(error), "source_construct")
            assertEquals(category, failure.category)
            assertEquals("unsupported_extension_abi", failure.errorCode)
            assertEquals("source_construct", failure.stage)
            assertFalse(failure.toString().contains("secret"))
            assertNull(failure.cause)
        }
    }

    private fun construct(type: Class<*>) = assertThrows(AniyomiRuntimeFailure::class.java) { execute(type.name) }
    private fun execute(name: String): JSONObject = AniyomiCompatRuntime.execute(javaClass.classLoader!!,
        JSONObject().put("kind", "anime").put("apiVersion", "14").put("classNames", JSONArray().put(name)),
        JSONObject().put("operation", "sources")) { error("Broker must not run") }
}

class MissingAbiConstructorFixture { init { throw NoSuchMethodError("secret provider path") } }
class UnsupportedConstructorFixture { init { throw UnsupportedOperationException("secret provider URL") } }
