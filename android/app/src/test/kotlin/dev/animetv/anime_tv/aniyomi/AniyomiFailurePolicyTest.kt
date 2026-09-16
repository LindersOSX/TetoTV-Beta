package dev.animetv.anime_tv.aniyomi

import org.junit.Assert.*
import org.junit.Test

class AniyomiFailurePolicyTest {
    @Test fun workerErrorStageAndCauseAreIndependentlyAllowlisted() {
        val result = AniyomiFailurePolicy.sanitize("unsupported_extension_abi", "source_construct", "method_missing")
        assertEquals(false, result["ok"])
        assertEquals("unsupported_extension_abi", result["error"])
        assertEquals("source_construct", result["stage"])
        assertEquals("method_missing", result["cause"])
    }

    @Test fun arbitraryWorkerDiagnosticTextNeverReachesDart() {
        val result = AniyomiFailurePolicy.sanitize(
            "token=secret", "https://secret.example", "/private/secret",
            "secret-host", 99, "secret-size", "secret-status",
        )
        assertEquals("extension_execution_failed", result["error"])
        assertEquals("unknown", result["stage"])
        assertEquals("execution", result["cause"])
        assertFalse(result.toString().contains("secret"))
        assertFalse(result.containsKey("broker_failure"))
    }

    @Test fun fixedBrokerTroubleshootingDimensionsSurviveTheBoundary() {
        val result = AniyomiFailurePolicy.sanitize(
            "extension_execution_failed", "source_operation", "io",
            "network", 2, "64to128k", "5xx",
        )
        assertEquals("network", result["broker_failure"])
        assertEquals(2, result["broker_redirect_count"])
        assertEquals("64to128k", result["broker_response_size_bucket"])
        assertEquals("5xx", result["broker_status_class"])
    }

    @Test fun hosterTimeoutCodeAndCauseSurviveTheClosedDiagnosticSchema() {
        val result = AniyomiFailurePolicy.sanitize(
            "extension_hoster_timeout",
            "source_videos",
            "timeout",
        )
        assertEquals("extension_hoster_timeout", result["error"])
        assertEquals("source_videos", result["stage"])
        assertEquals("timeout", result["cause"])
    }

    @Test fun everyFixedBrokerFailureCategoryKeepsOnlyBoundedTroubleshootingContext() {
        for (failure in listOf("policy", "network", "unsupported", "invalid")) {
            val result = AniyomiFailurePolicy.sanitize(
                "extension_execution_failed",
                "source_videos",
                "execution",
                failure,
                3,
                "128to256k",
                "3xx",
            )
            assertEquals(failure, result["broker_failure"])
            assertEquals(3, result["broker_redirect_count"])
            assertEquals("128to256k", result["broker_response_size_bucket"])
            assertEquals("3xx", result["broker_status_class"])
            assertFalse(result.toString().contains("http"))
        }
    }

    @Test fun normalResponseContextSurvivesOnlyOnAnOverallProviderFailure() {
        val result = AniyomiFailurePolicy.sanitize(
            "extension_execution_failed", "source_search", "execution",
            "", 1, "lt64k", "4xx",
        )
        assertFalse(result.containsKey("broker_failure"))
        assertEquals(1, result["broker_redirect_count"])
        assertEquals("lt64k", result["broker_response_size_bucket"])
        assertEquals("4xx", result["broker_status_class"])
    }
}
