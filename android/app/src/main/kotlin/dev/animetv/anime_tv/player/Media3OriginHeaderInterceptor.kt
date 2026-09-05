package dev.animetv.anime_tv.player

import okhttp3.Interceptor
import okhttp3.Response

/** A network interceptor sees every redirect, segment and sidecar destination. */
internal class Media3OriginHeaderInterceptor(
    private val originalUri: String,
    private val suppliedHeaderNames: Set<String>,
) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        if (Media3BridgePolicy.sameOrigin(originalUri, request.url.toString())) {
            return chain.proceed(request)
        }
        val safe = request.newBuilder()
        suppliedHeaderNames.forEach(safe::removeHeader)
        safe.removeHeader("Authorization")
        safe.removeHeader("Cookie")
        safe.removeHeader("Proxy-Authorization")
        return chain.proceed(safe.build())
    }
}
