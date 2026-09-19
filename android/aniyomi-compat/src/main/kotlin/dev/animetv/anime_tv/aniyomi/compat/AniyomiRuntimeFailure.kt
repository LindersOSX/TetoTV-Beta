package dev.animetv.anime_tv.aniyomi.compat

import java.io.IOException
import java.lang.reflect.InvocationTargetException
import java.util.concurrent.CompletionException
import java.util.concurrent.ExecutionException
import java.util.concurrent.TimeoutException
import kotlinx.coroutines.TimeoutCancellationException

/**
 * Fixed, privacy-safe markers returned by the trusted HTTP broker.
 *
 * Do not attach the provider URL, exception message or stack from the host
 * process. The superclass is deliberate: [AniyomiRuntimeFailure] turns these
 * into the existing public diagnostic categories without exposing targets.
 */
data class AniyomiBrokerDiagnosticContext(
    val redirectCount: Int = 0,
    val responseSizeBucket: String = "none",
    val statusClass: String = "none",
    val reason: String = "none",
) {
    init {
        require(redirectCount in 0..3) { "invalid_broker_redirect_count" }
        require(responseSizeBucket in SIZE_BUCKETS) { "invalid_broker_size_bucket" }
        require(statusClass in STATUS_CLASSES) { "invalid_broker_status_class" }
        require(reason in REASONS) { "invalid_broker_reason" }
    }

    companion object {
        val SIZE_BUCKETS = setOf("none", "lt64k", "64to128k", "128to256k", "over256k")
        val STATUS_CLASSES = setOf("none", "1xx", "2xx", "3xx", "4xx", "5xx")
        val REASONS = setOf(
            "none", "client_configuration", "credential_header", "request_method", "request_headers",
            "request_body", "transport_mutation", "direct_network", "request_envelope",
            "client_websocket", "client_chain", "client_network_interceptor", "client_proxy", "client_cache",
            "http_method_unsupported", "get_body_unsupported", "http_request_too_large",
            "http_headers_too_large", "http_header_not_permitted", "unsupported_http_field",
            "http_request_limit", "invalid_http_option", "http_redirect_unsupported",
            "http_redirect_limit", "http_response_too_large",
        )
        val EMPTY = AniyomiBrokerDiagnosticContext()
    }
}

interface AniyomiBrokerDiagnostic {
    val brokerFailure: String
    val brokerContext: AniyomiBrokerDiagnosticContext
}

class AniyomiBrokerPolicyDenied(
    override val brokerContext: AniyomiBrokerDiagnosticContext = AniyomiBrokerDiagnosticContext.EMPTY,
) : SecurityException(CODE), AniyomiBrokerDiagnostic {
    override val brokerFailure = "policy"
    companion object { const val CODE = "http_broker_unsafe_target" }
}

class AniyomiBrokerNetworkFailure(
    override val brokerContext: AniyomiBrokerDiagnosticContext = AniyomiBrokerDiagnosticContext.EMPTY,
) : IOException(CODE), AniyomiBrokerDiagnostic {
    override val brokerFailure = "network"
    companion object { const val CODE = "http_broker_network" }
}

class AniyomiBrokerUnsupportedCapability(
    override val brokerContext: AniyomiBrokerDiagnosticContext = AniyomiBrokerDiagnosticContext.EMPTY,
) : UnsupportedOperationException(CODE), AniyomiBrokerDiagnostic {
    override val brokerFailure = "unsupported"
    companion object { const val CODE = "http_broker_unsupported" }
}

class AniyomiBrokerInvalidResponse(
    override val brokerContext: AniyomiBrokerDiagnosticContext = AniyomiBrokerDiagnosticContext.EMPTY,
) : IllegalArgumentException(CODE), AniyomiBrokerDiagnostic {
    override val brokerFailure = "invalid"
    companion object { const val CODE = "http_broker_invalid_response" }
}

/** Fixed diagnostics only: never serialize provider exception messages, names or stacks. */
class AniyomiRuntimeFailure private constructor(
    val stage: String,
    val category: String,
    val errorCode: String,
    val brokerFailure: String? = null,
    val brokerRedirectCount: Int? = null,
    val brokerResponseSizeBucket: String? = null,
    val brokerStatusClass: String? = null,
    val brokerReason: String? = null,
) : RuntimeException("$stage:$category") {
    internal fun withFallbackBrokerContext(context: AniyomiBrokerDiagnosticContext?): AniyomiRuntimeFailure {
        if (context == null || brokerFailure != null || brokerRedirectCount != null ||
            brokerResponseSizeBucket != null || brokerStatusClass != null
        ) return this
        return AniyomiRuntimeFailure(
            stage = stage,
            category = category,
            errorCode = errorCode,
            brokerRedirectCount = context.redirectCount,
            brokerResponseSizeBucket = context.responseSizeBucket,
            brokerStatusClass = context.statusClass,
        )
    }

    companion object {
        fun <T> atStage(stage: String, action: () -> T): T = try {
            action()
        } catch (error: Throwable) {
            if (error is VirtualMachineError || error is ThreadDeath) throw error
            throw describe(error, stage)
        }

        fun describe(error: Throwable, fallbackStage: String): AniyomiRuntimeFailure {
            if (error is AniyomiRuntimeFailure) return error
            var cause = error
            // Constructor/static-initializer bridges hide missing ABI and capability failures.
            // Unwrap only known wrappers, with a fixed work bound even for cyclic causes.
            for (ignored in 0 until 8) {
                val nested = when (cause) {
                    is InvocationTargetException -> cause.targetException
                    is ExceptionInInitializerError -> cause.exception
                    is ExecutionException, is CompletionException -> cause.cause
                    // Aniyomi's await bridge wraps transport failures in a
                    // plain IOException. Unwrap only our fixed diagnostic
                    // type; arbitrary provider exception chains remain opaque.
                    is IOException -> brokerDiagnosticCause(cause)
                    else -> null
                } ?: break
                if (nested === cause) break
                cause = nested
            }
            if (cause is AniyomiRuntimeFailure) return cause
            val category = when (cause) {
                is ClassNotFoundException, is NoClassDefFoundError -> "class_missing"
                is NoSuchMethodException, is NoSuchMethodError -> "method_missing"
                is NoSuchFieldException, is NoSuchFieldError -> "field_missing"
                is AbstractMethodError -> "abstract_method"
                is ExceptionInInitializerError -> "class_initialization"
                is VerifyError -> "verify_error"
                is IllegalAccessError -> "illegal_access"
                is IncompatibleClassChangeError -> "incompatible_class_change"
                is ClassFormatError -> "class_format"
                is UnsatisfiedLinkError -> "native_linkage"
                is LinkageError -> "linkage"
                is UnsupportedOperationException -> "unsupported_capability"
                is SecurityException -> "security_denied"
                is TimeoutException, is TimeoutCancellationException -> "timeout"
                is IllegalArgumentException -> "invalid_input"
                is IOException -> "io"
                else -> "execution"
            }
            val code = if (cause is AniyomiResultLimitExceeded) {
                "extension_result_too_large"
            } else when (category) {
                "class_missing", "method_missing", "field_missing", "abstract_method", "class_initialization",
                "verify_error", "illegal_access", "incompatible_class_change", "class_format", "native_linkage", "linkage" ->
                    "unsupported_extension_abi"
                "unsupported_capability", "security_denied" -> "unsupported_extension_capability"
                "timeout" -> "extension_hoster_timeout"
                else -> "extension_execution_failed"
            }
            val broker = cause as? AniyomiBrokerDiagnostic
            return AniyomiRuntimeFailure(
                fallbackStage,
                category,
                code,
                brokerFailure = broker?.brokerFailure,
                brokerRedirectCount = broker?.brokerContext?.redirectCount,
                brokerResponseSizeBucket = broker?.brokerContext?.responseSizeBucket,
                brokerStatusClass = broker?.brokerContext?.statusClass,
                brokerReason = broker?.brokerContext?.reason?.takeUnless { it == "none" },
            )
        }

        private fun brokerDiagnosticCause(error: IOException): Throwable? {
            var current: Throwable = error
            // The transport and Aniyomi's await bridge each add an IOException
            // wrapper. Follow only IO wrappers, and only retain a typed broker
            // marker; other provider-controlled exception chains stay opaque.
            repeat(8) {
                current = (current as? IOException)?.cause ?: return null
                if (current is AniyomiBrokerDiagnostic) return current
            }
            return null
        }
    }
}
