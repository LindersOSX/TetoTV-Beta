package dev.animetv.anime_tv.aniyomi

import dev.animetv.anime_tv.aniyomi.compat.AniyomiBrokerDiagnosticContext

/** Treat worker diagnostics as untrusted input, just like provider result fields. */
internal object AniyomiFailurePolicy {
    private val errors = setOf("unsupported_extension_capability", "unsupported_extension_abi",
        "extension_execution_failed", "extension_result_too_large", "extension_hoster_timeout")
    private val stages = setOf("dex_load", "runtime_setup", "class_load", "source_construct", "source_factory",
        "source_describe", "source_select", "source_operation", "source_search", "source_details", "source_seasons",
        "source_episodes", "source_chapters", "source_hosters", "source_videos", "source_pages", "source_image_url")
    private val causes = setOf("class_missing", "method_missing", "field_missing", "abstract_method",
        "class_initialization", "verify_error", "illegal_access", "incompatible_class_change", "class_format", "native_linkage",
        "linkage", "unsupported_capability", "security_denied", "invalid_input", "io", "timeout", "execution")

    private val brokerFailures = setOf("policy", "network", "unsupported", "invalid")
    private val responseSizeBuckets = setOf("none", "lt64k", "64to128k", "128to256k", "over256k")
    private val statusClasses = setOf("none", "1xx", "2xx", "3xx", "4xx", "5xx")

    fun sanitize(
        error: String,
        stage: String,
        cause: String,
        brokerFailure: String = "",
        brokerRedirectCount: Int = -1,
        brokerResponseSizeBucket: String = "",
        brokerStatusClass: String = "",
        brokerReason: String = "",
    ): Map<String, Any?> = mutableMapOf<String, Any?>(
        "ok" to false,
        "error" to error.takeIf { it in errors }.orEmpty().ifEmpty { "extension_execution_failed" },
        "stage" to stage.takeIf { it in stages }.orEmpty().ifEmpty { "unknown" },
        "cause" to cause.takeIf { it in causes }.orEmpty().ifEmpty { "execution" },
    ).apply {
        val boundedContext = brokerRedirectCount in 0..3 &&
            brokerResponseSizeBucket in responseSizeBuckets && brokerStatusClass in statusClasses
        if (boundedContext && (brokerFailure.isEmpty() || brokerFailure in brokerFailures)) {
            if (brokerFailure in brokerFailures) put("broker_failure", brokerFailure)
            put("broker_redirect_count", brokerRedirectCount)
            put("broker_response_size_bucket", brokerResponseSizeBucket)
            put("broker_status_class", brokerStatusClass)
            if (brokerReason != "none" && brokerReason in AniyomiBrokerDiagnosticContext.REASONS) {
                put("broker_reason", brokerReason)
            }
        }
    }
}
