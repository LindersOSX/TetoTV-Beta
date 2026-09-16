// Compatibility ABI adapted from Aniyomi; Apache-2.0.
package eu.kanade.tachiyomi.network

import android.content.Context
import app.cash.quickjs.QuickJs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Link-compatible JavaScript service backed by Aniyomi's pinned QuickJS.
 *
 * QuickJS exposes ECMAScript only: it receives no Context, Java object, file,
 * WebView, or network bridge. Every evaluation owns and closes its engine.
 * Non-cooperative native work remains contained by the one-shot isolated
 * worker's independent hard deadline.
 */
@Suppress("UNUSED", "UNUSED_PARAMETER", "UNCHECKED_CAST")
class JavaScriptEngine private constructor(
    private val evaluator: (String) -> Any?,
    @Suppress("UNUSED_PARAMETER") marker: Unit,
) {
    constructor(context: Context) : this(::evaluateWithQuickJs, Unit)

    internal constructor(evaluator: (String) -> Any?) : this(evaluator, Unit)

    suspend fun <T> evaluate(script: String): T = withContext(Dispatchers.IO) {
        checkTextBound(script, MAX_SCRIPT_BYTES, "javascript_input_too_large")
        val result = evaluator(script)
        when (result) {
            null, is Boolean, is Int -> Unit
            is Double -> if (!result.isFinite()) unsupported("javascript_result_invalid")
            is String -> checkTextBound(result, MAX_RESULT_BYTES, "javascript_result_too_large")
            else -> unsupported("javascript_result_type_unsupported")
        }
        result as T
    }

    private companion object {
        const val MAX_SCRIPT_BYTES = 256 * 1024
        const val MAX_RESULT_BYTES = 256 * 1024

        fun evaluateWithQuickJs(script: String): Any? = QuickJs.create().use { it.evaluate(script) }

        fun checkTextBound(value: String, maximum: Int, code: String) {
            if (value.length > maximum || value.toByteArray(Charsets.UTF_8).size > maximum) unsupported(code)
        }

        fun unsupported(code: String): Nothing = throw UnsupportedOperationException(code)
    }
}
