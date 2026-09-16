package dev.animetv.anime_tv.aniyomi

import java.net.InetAddress
import java.net.URI

/** All values crossing the experimental provider boundary are treated as untrusted. */
internal object AniyomiPolicy {
    const val MAX_APK_BYTES = 32 * 1024 * 1024
    const val MAX_DEX_BYTES = 48 * 1024 * 1024
    const val MAX_REQUEST_BYTES = 32 * 1024
    const val MAX_REPLY_BYTES = 192 * 1024
    // Bodies use read-only, unlinked file descriptors, not base64 in Binder's
    // process-shared 1-MiB transaction buffer. Only small metadata is parceled.
    const val MAX_HTTP_BYTES = 4 * 1024 * 1024
    const val MAX_HTTP_REPLY_BYTES = 16 * 1024
    const val MAX_HTTP_REQUESTS = 16
    const val DEADLINE_MS = 30_000L
    // Per-operation budget supplied by Flutter. The native worker keeps its
    // independent 30-second hard deadline; this value is transport metadata
    // and is deliberately not forwarded into extension code.
    const val MAX_OPERATION_BUDGET_MS = 10_000L
    val operations = setOf("sources", "search", "details", "seasons", "chapters", "episodes", "pages", "videos")
    private val packagePattern = Regex("[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+")
    private val digestPattern = Regex("[0-9a-f]{64}")

    fun validIdentity(packageName: String, version: Long, apkHash: String, certificate: String): Boolean =
        packageName.length <= 200 && packagePattern.matches(packageName) && version > 0 &&
            digestPattern.matches(apkHash) && digestPattern.matches(certificate)

    fun apiVersion(kind: String, versionName: String, declaredLibrary: String? = null): String {
        require(versionName.length <= 80) { "invalid_version" }
        return when (kind) {
            "anime" -> {
                // Current Anime Store packages declare their source API in
                // `aniyomix.extensionLib`. Legacy repositories encode it in
                // versionName (for example 14.5). Match Aniyomi's published
                // loader range while retaining the legacy fallback.
                val raw = declaredLibrary?.trim()?.takeIf { it.isNotEmpty() }
                    ?: versionName.substringBeforeLast('.', versionName)
                require(raw.length <= 20 && raw.matches(Regex("[0-9]+(?:\\.[0-9]+)?"))) {
                    "invalid_anime_api"
                }
                val normalized = raw.toDoubleOrNull()
                require(normalized == 14.0 || normalized == 16.0) { "unsupported_anime_api" }
                normalized.toInt().toString()
            }
            "manga" -> versionName.split('.').take(2).joinToString(".").also {
                require(it == "1.4" || it == "1.5") { "unsupported_manga_api" }
            }
            else -> throw IllegalArgumentException("invalid_kind")
        }
    }

    fun publicHttps(raw: String): URI {
        require(raw.length in 1..4096 && raw.none { it <= ' ' || it == '\\' }) { "invalid_https_url" }
        val uri = URI(raw)
        val host = uri.host?.lowercase() ?: throw IllegalArgumentException("invalid_https_host")
        require(uri.scheme.equals("https", true) && uri.rawUserInfo == null && uri.rawFragment == null) {
            "public_https_required"
        }
        require(uri.port == -1 || uri.port == 443) { "https_port_not_allowed" }
        require(host.length <= 253 && !host.endsWith('.') && host.contains('.') &&
            !host.endsWith(".localhost") && !host.endsWith(".local") && !host.endsWith(".internal") &&
            !host.endsWith(".home.arpa") && host != "metadata.google.internal") { "private_host_blocked" }
        if (host.matches(Regex("[0-9.]+"))) {
            require(publicAddress(InetAddress.getByName(host))) { "private_host_blocked" }
        }
        return uri
    }

    /** Conservative global-unicast policy; reject every answer, not only the chosen DNS answer. */
    fun publicAddress(address: InetAddress): Boolean {
        if (address.isAnyLocalAddress || address.isLoopbackAddress || address.isLinkLocalAddress ||
            address.isSiteLocalAddress || address.isMulticastAddress) return false
        val bytes = address.address.map { it.toInt() and 255 }
        if (bytes.size == 4) {
            val a = bytes[0]; val b = bytes[1]; val c = bytes[2]
            return !(a == 0 || a == 10 || a == 127 || a >= 224 ||
                (a == 100 && b in 64..127) || (a == 169 && b == 254) ||
                (a == 172 && b in 16..31) || (a == 192 && b == 168) ||
                (a == 192 && b == 0) || (a == 192 && b == 88 && c == 99) ||
                (a == 198 && b in 18..19) || (a == 198 && b == 51 && c == 100) ||
                (a == 203 && b == 0 && c == 113))
        }
        // Excludes unique-local, mapped IPv4, NAT64 and transition addresses.
        return bytes.size == 16 && bytes[0] in 0x20..0x3f &&
            !(bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8) &&
            !(bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0 && bytes[3] == 0) &&
            !(bytes[0] == 0x20 && bytes[1] == 0x02)
    }

    fun boundedText(value: String, maximum: Int): String {
        require(value.toByteArray(Charsets.UTF_8).size <= maximum && '\u0000' !in value) { "payload_too_large" }
        return value
    }

    /** Bound parser recursion BEFORE constructing JSONObject from a compromised worker's text. */
    fun boundedJsonText(value: String, maximum: Int): String {
        boundedText(value, maximum)
        var quoted = false
        var escaped = false
        var depth = 0
        val bare = " \t\r\n:,-+.0123456789eEtruefalsn"
        for (character in value) {
            if (quoted) {
                require(character >= ' ') { "invalid_json_control" }
                when {
                    escaped -> escaped = false
                    character == '\\' -> escaped = true
                    character == '"' -> quoted = false
                }
            } else {
                when (character) {
                    '"' -> quoted = true
                    '{', '[' -> { depth++; require(depth <= 16) { "json_nesting_limit" } }
                    '}', ']' -> { depth--; require(depth >= 0) { "invalid_json" } }
                    // Android's lenient parser also accepts comments/single quotes/unquoted
                    // strings. Exclude those so lexical depth cannot disagree with its parser.
                    else -> require(character in bare) { "invalid_json_character" }
                }
            }
        }
        require(!quoted && depth == 0) { "invalid_json" }
        return value
    }
}

/** No positive decision is cached: developer mode and generation are checked for every use. */
internal class AniyomiLease(private val enabled: () -> Boolean) {
    @Volatile private var generation = 0L
    @Synchronized fun issue(): Long {
        check(enabled()) { "developer_mode_required" }
        return generation
    }
    fun check(lease: Long) {
        check(enabled() && lease == generation) { "developer_access_revoked" }
    }
    @Synchronized fun revoke() { generation++ }
}
