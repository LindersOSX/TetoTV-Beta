package dev.animetv.anime_tv.aniyomi

import aniyomi.lib.m3u8server.M3u8ServerManager
import dev.animetv.anime_tv.aniyomi.compat.AniyomiCompatRuntime
import eu.kanade.tachiyomi.animesource.AnimeSource
import eu.kanade.tachiyomi.network.NetworkHelper
import java.io.File
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class AniyomiExtensionParentClassLoaderTest {
    private val runtime = javaClass.classLoader!!
    @get:Rule val temporary = TemporaryFolder()

    @Test fun independentlyObfuscatedConcreteHelperDoesNotResolveToHostInterface() {
        val host = ByteLoader(runtime, mapOf("f" to compile("public interface f {}")))
        val bytes = mapOf("f" to compile("public final class f { public String value() { return \"extension\"; } }"))
        val broken = ByteLoader(host, bytes)
        assertTrue(broken.loadClass("f").isInterface)

        val extension = ByteLoader(AniyomiExtensionParentClassLoader(host), bytes)
        val helper = extension.loadClass("f")
        assertFalse(helper.isInterface)
        assertSame(extension, helper.classLoader)
        assertEquals("extension", helper.getMethod("value").invoke(helper.getDeclaredConstructor().newInstance()))
        assertNotSame(host.loadClass("f"), helper)
    }

    @Test fun platformAndSharedSourceLibraryTypesKeepCanonicalIdentity() {
        val extension = ByteLoader(AniyomiExtensionParentClassLoader(runtime), emptyMap())
        for (type in listOf(
            String::class.java, org.json.JSONObject::class.java, kotlin.Unit::class.java,
            AnimeSource::class.java, eu.kanade.tachiyomi.source.Source::class.java,
            okhttp3.OkHttpClient::class.java, okio.Buffer::class.java,
            rx.Observable::class.java, kotlinx.coroutines.Job::class.java,
            kotlinx.serialization.json.Json::class.java, org.jsoup.Jsoup::class.java,
        )) assertSame(type.name, type, extension.loadClass(type.name))
        assertEquals(0, extension.childLookups)
    }

    @Test fun brokerAndRuntimeCannotBeShadowedByExtensionCopies() {
        val shared = listOf(
            NetworkHelper::class.java,
            AniyomiCompatRuntime::class.java,
            AniyomiPolicy::class.java,
            M3u8ServerManager::class.java,
        )
        val extension = ByteLoader(AniyomiExtensionParentClassLoader(runtime), shared.associate { type ->
            type.name to runtime.getResourceAsStream(type.name.replace('.', '/') + ".class")!!.use { it.readBytes() }
        })
        shared.forEach { assertSame(it, extension.loadClass(it.name)) }
        assertEquals(0, extension.childLookups)
    }

    @Test fun missingSharedClassFailsClosedInsteadOfFallingBackToApk() {
        val extension = ByteLoader(AniyomiExtensionParentClassLoader(runtime), emptyMap())
        for (name in listOf(
            "dev.animetv.anime_tv.aniyomi.AbsentBroker", "eu.kanade.tachiyomi.network.AbsentHelper",
            "eu.kanade.tachiyomi.animesource.AbsentContract", "uy.kohesive.injekt.AbsentRegistry",
            "androidx.preference.AbsentPreference", "org.json.AbsentPlatformClass",
        )) assertThrows(NoClassDefFoundError::class.java) { extension.loadClass(name) }
        assertEquals(0, extension.childLookups)
    }

    @Test fun extensionNamespacesAndNearPrefixNamesNeverDelegateToHost() {
        var hostLookups = 0
        val host = object : ClassLoader(null) {
            override fun loadClass(name: String, resolve: Boolean): Class<*> {
                hostLookups++
                throw AssertionError("Unrelated host namespace consulted")
            }
        }
        val parent = AniyomiExtensionParentClassLoader(host)
        for (name in listOf(
            "f", "dev.animetv.anime_tv.MainActivity", "dev.animetv.anime_tv.aniyomix.Helper",
            "eu.kanade.tachiyomi.animeextension.en.animegg.AnimeGG",
            "aniyomi.lib.m3u8server.M3u8HttpServer",
            "eu.kanade.tachiyomi.extension.en.fixture.Source", "okhttp3x.Client", "kotlinxCustom.Helper",
        )) assertThrows(ClassNotFoundException::class.java) { parent.loadClass(name) }
        assertSame(String::class.java, parent.loadClass("java.lang.String"))
        assertEquals(0, hostLookups)
    }

    /** First-party bytecode only; no APK or provider execution in JVM tests. */
    private fun compile(source: String): ByteArray {
        // Android's unit-test compile bootclasspath omits javax.tools; use the
        // same JDK's javac for these two tiny generated, local fixture classes.
        val directory = temporary.newFolder()
        File(directory, "f.java").writeText(source)
        val executable = if (System.getProperty("os.name").orEmpty().startsWith("Windows")) "javac.exe" else "javac"
        val compiler = File(System.getProperty("java.home"), "bin/$executable")
        val process = ProcessBuilder(compiler.absolutePath, "-source", "17", "-target", "17", "-proc:none", "f.java")
            .directory(directory).redirectErrorStream(true).start()
        try {
            check(process.waitFor(20, TimeUnit.SECONDS)) { "First-party fixture compiler timed out" }
            check(process.exitValue() == 0) { process.inputStream.bufferedReader().readText() }
        } finally {
            if (process.isAlive) process.destroyForcibly()
        }
        return File(directory, "f.class").readBytes()
    }

    private class ByteLoader(parent: ClassLoader, private val classes: Map<String, ByteArray>) : ClassLoader(parent) {
        var childLookups = 0
        override fun findClass(name: String): Class<*> {
            childLookups++
            val bytes = classes[name] ?: throw ClassNotFoundException(name)
            return defineClass(name, bytes, 0, bytes.size)
        }
    }
}
