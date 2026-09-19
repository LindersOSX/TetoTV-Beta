package dev.animetv.anime_tv.aniyomi

/**
 * Parent of the in-memory extension DEX loader, never an extension executor.
 *
 * Unrelated app classes (including R8's root-package names) must not win over
 * classes bundled by an independently shrunk extension. Only platform classes
 * and the canonical compatibility/runtime libraries are visible from the host.
 * OS isolated-UID enforcement, not this namespace policy, is the sandbox.
 */
internal class AniyomiExtensionParentClassLoader(
    private val runtimeLoader: ClassLoader,
    private val resources: AniyomiApkResources = AniyomiApkResources(),
) : ClassLoader(null) {
    // InMemoryDexClassLoader has no APK path to search for assets. Its parent
    // supplies only the bounded resources extracted from the same verified APK.
    override fun getResource(name: String): java.net.URL? = resources.find(name)
    override fun getResources(name: String): java.util.Enumeration<java.net.URL> =
        java.util.Collections.enumeration(listOfNotNull(getResource(name)))

    override fun loadClass(name: String, resolve: Boolean): Class<*> {
        // Use the real bootstrap loader, not the app's parent chain. This also
        // preserves less obvious platform APIs such as org.json on Android.
        try {
            return Class.forName(name, false, null)
        } catch (_: ClassNotFoundException) {
            // Only an absent boot class may be considered below.
        }
        if (name !in SHARED_CLASSES && SHARED_PREFIXES.none(name::startsWith)) {
            throw ClassNotFoundException(name)
        }
        try {
            return runtimeLoader.loadClass(name)
        } catch (_: ClassNotFoundException) {
            // A CNFE would tell InMemoryDexClassLoader to fall back to an APK's
            // shadow copy of this shared ABI/broker. Fail closed instead.
            throw NoClassDefFoundError("shared_runtime_class_unavailable")
        }
    }

    private companion object {
        val SHARED_CLASSES = setOf(
            // Exact socket-free bridge. Other extension-bundled helper classes
            // in this namespace remain child-owned.
            "aniyomi.lib.m3u8server.M3u8ServerManager",
        )
        val SHARED_PREFIXES = listOf(
            "java.", "javax.", "android.", "androidx.", "dalvik.", "libcore.",
            "org.json.", "org.xml.", "org.w3c.", "org.apache.http.",
            "kotlin.", "kotlinx.", "rx.", "okhttp3.", "okio.", "org.jsoup.",
            "app.cash.quickjs.",
            "uy.kohesive.injekt.", "dev.mihon.injekt.",
            "eu.kanade.tachiyomi.animesource.", "eu.kanade.tachiyomi.source.",
            "eu.kanade.tachiyomi.network.", "eu.kanade.tachiyomi.util.",
            "tachiyomi.core.common.util.lang.",
            "dev.animetv.anime_tv.aniyomi.",
        )
    }
}
