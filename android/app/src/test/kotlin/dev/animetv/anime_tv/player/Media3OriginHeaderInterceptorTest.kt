package dev.animetv.anime_tv.player

import okhttp3.OkHttpClient
import okhttp3.Request
import org.junit.Assert.*
import org.junit.Test
import java.net.InetAddress
import java.net.ServerSocket
import java.util.Collections
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class Media3OriginHeaderInterceptorTest {
    @Test fun credentialsSurviveSameOriginRedirectButNeverCrossOriginRedirectOrSidecar() {
        val received = Collections.synchronizedList(mutableListOf<Map<String, String>>())
        val source = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1")).apply { soTimeout = 5_000 }
        val other = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1")).apply { soTimeout = 5_000 }
        val origin = "http://127.0.0.1:${source.localPort}"
        val destination = "http://127.0.0.1:${other.localPort}"
        val executor = Executors.newFixedThreadPool(2)
        fun serve(server: ServerSocket, redirect: Boolean) = executor.submit {
            repeat(2) {
                server.accept().use { socket ->
                    socket.soTimeout = 5_000
                    val reader = socket.getInputStream().bufferedReader(Charsets.US_ASCII)
                    val path = reader.readLine().split(' ')[1]
                    val headers = mutableMapOf("path" to path)
                    while (true) {
                        val line = reader.readLine() ?: break
                        if (line.isEmpty()) break
                        headers[line.substringBefore(':').lowercase()] = line.substringAfter(':').trim()
                    }
                    received.add(headers)
                    val response = if (redirect) {
                        val target = if (path == "/start") "$origin/same" else "$destination/end"
                        "HTTP/1.1 302 Found\r\nLocation: $target\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    } else "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
                    socket.getOutputStream().write(response.toByteArray(Charsets.US_ASCII))
                }
            }
        }
        val client = OkHttpClient.Builder()
            .callTimeout(5, TimeUnit.SECONDS)
            .addNetworkInterceptor(Media3OriginHeaderInterceptor(origin, setOf("Authorization", "X-Provider-Key", "Cookie")))
            .build()
        try {
            val first = serve(source, true)
            val second = serve(other, false)
            fun request(url: String) = Request.Builder().url(url).header("Authorization", "Bearer fixture").header("X-Provider-Key", "fixture").header("Cookie", "fixture=1").build()
            client.newCall(request("$origin/start")).execute().use { assertEquals(200, it.code) }
            client.newCall(request("$destination/sidecar")).execute().use { assertEquals(200, it.code) }
            first.get(5, TimeUnit.SECONDS)
            second.get(5, TimeUnit.SECONDS)
            assertEquals(listOf("/start", "/same", "/end", "/sidecar"), received.map { it["path"] })
            for (item in received.take(2)) {
                assertEquals("Bearer fixture", item["authorization"])
                assertEquals("fixture", item["x-provider-key"])
            }
            for (item in received.drop(2)) {
                assertNull(item["authorization"])
                assertNull(item["x-provider-key"])
                assertNull(item["cookie"])
            }
        } finally {
            source.close()
            other.close()
            executor.shutdownNow()
            client.connectionPool.evictAll()
            client.dispatcher.executorService.shutdownNow()
        }
    }
}
