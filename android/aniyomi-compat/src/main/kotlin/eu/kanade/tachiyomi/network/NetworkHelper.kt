// TetoTV implementation of Aniyomi's NetworkHelper public ABI.
// No Context, Application, WebView, persisted cookie store or direct transport.
package eu.kanade.tachiyomi.network

import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.Dns
import okhttp3.HttpUrl
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import java.io.IOException
import java.util.concurrent.TimeUnit

class NetworkHelper(transport: Interceptor) {
    val cookieJar = AndroidCookieJar()
    val client: OkHttpClient = OkHttpClient.Builder()
        .cookieJar(cookieJar)
        // Preserve OkHttp defaults. Provider clones that explicitly disable
        // either redirect mode are carried as booleans to the trusted broker.
        .followRedirects(true)
        .followSslRedirects(true)
        .retryOnConnectionFailure(false)
        .callTimeout(15, TimeUnit.SECONDS)
        // Terminal interceptor: returns the IPC broker response and never calls proceed.
        .addInterceptor(transport)
        .dns(object : Dns {
            override fun lookup(hostname: String): List<java.net.InetAddress> =
                throw IOException("Direct DNS is unavailable in this runtime")
        })
        .build()
    val nonCloudflareClient: OkHttpClient get() = client
    val cloudflareClient: OkHttpClient get() = client
    fun defaultUserAgentProvider(): String = "TetoTV-Experimental-Aniyomi/1"
}

/** Cookie ABI is present but authenticated sessions are intentionally unsupported. */
class AndroidCookieJar : CookieJar {
    override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
        if (cookies.isNotEmpty()) throw UnsupportedOperationException("Provider cookies are unavailable")
    }
    override fun loadForRequest(url: HttpUrl): List<Cookie> = emptyList()
    fun remove(url: HttpUrl) = Unit
    fun removeAll() = Unit
}
