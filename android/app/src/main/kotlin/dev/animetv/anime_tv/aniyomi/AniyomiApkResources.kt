package dev.animetv.anime_tv.aniyomi

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.URL
import java.net.URLConnection
import java.net.URLStreamHandler

/** Bounded read-only assets from this verified APK, never from host files or the network. */
internal class AniyomiApkResources {
    private val entries = linkedMapOf<String, ByteArray>()
    private var totalBytes = 0

    fun readEntry(name: String, input: InputStream) {
        require(validName(name)) { "invalid_apk_resource" }
        require(name !in entries && entries.size < MAX_ENTRIES) { "apk_resource_limit" }
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(8 * 1024)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            require(output.size() + count <= MAX_ENTRY_BYTES && totalBytes + count <= MAX_TOTAL_BYTES) {
                "apk_resource_limit"
            }
            totalBytes += count
            output.write(buffer, 0, count)
        }
        entries[name] = output.toByteArray()
    }

    fun find(name: String): URL? {
        if (!validName(name)) return null
        val bytes = entries[name] ?: return null
        return URL(null, "aniyomi-asset:/$name", object : URLStreamHandler() {
            override fun openConnection(url: URL): URLConnection {
                // A derived URL must not accidentally serve the originally captured asset.
                require(url.toExternalForm() == "aniyomi-asset:/$name") { "invalid_apk_resource" }
                return object : URLConnection(url) {
                    override fun connect() { connected = true }
                    override fun getInputStream(): InputStream = ByteArrayInputStream(bytes)
                    override fun getContentLength(): Int = bytes.size
                    override fun getContentLengthLong(): Long = bytes.size.toLong()
                }
            }
        })
    }

    companion object {
        const val MAX_ENTRIES = 256
        const val MAX_ENTRY_BYTES = 1024 * 1024
        const val MAX_TOTAL_BYTES = 8 * 1024 * 1024
        fun validName(name: String): Boolean = name.length in 1..512 &&
            (name.startsWith("assets/") || name.startsWith("res/raw/")) &&
            name.split('/').all { it.isNotEmpty() && it != "." && it != ".." && it.matches(Regex("[A-Za-z0-9_.-]+")) }
    }
}
