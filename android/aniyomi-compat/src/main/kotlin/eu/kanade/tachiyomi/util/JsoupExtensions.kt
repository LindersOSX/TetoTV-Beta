// Aniyomi 39e9a749590b89b432f04b83725aaa12591371b2; Apache-2.0.
// Modified by TetoTV: require a body explicitly at the compatibility boundary.
// See third_party/aniyomi_compat/README.md for provenance and supported scope.
package eu.kanade.tachiyomi.util

import okhttp3.Response
import org.jsoup.Jsoup
import org.jsoup.nodes.Document
import org.jsoup.nodes.Element

fun Element.selectText(css: String, defaultValue: String? = null): String? {
    return select(css).first()?.text() ?: defaultValue
}

fun Element.selectInt(css: String, defaultValue: Int = 0): Int {
    return select(css).first()?.text()?.toInt() ?: defaultValue
}

fun Element.attrOrText(css: String): String {
    return if (css != "text") attr(css) else text()
}

/**
 * Returns a Jsoup document for this response.
 * @param html the body of the response. Use only if the body was read before calling this method.
 */
fun Response.asJsoup(html: String? = null): Document {
    return Jsoup.parse(html ?: requireNotNull(body).string(), request.url.toString())
}
