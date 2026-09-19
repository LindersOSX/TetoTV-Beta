package dev.animetv.anime_tv.aniyomi

import java.io.InputStreamReader
import java.net.URL
import java.util.PropertyResourceBundle
import org.junit.Assert.*
import org.junit.Test

class AniyomiApkResourcesTest {
    @Test fun intlStyleLookupCanReadUtf8LabelsThroughDexParentWithoutHostAssets() {
        val assets = AniyomiApkResources().apply {
            readEntry("assets/i18n/messages_en.properties", "search=Search\ntitle=Résumé".byteInputStream())
        }
        val parent = AniyomiExtensionParentClassLoader(javaClass.classLoader!!, assets)
        val child = object : ClassLoader(parent) {}
        val path = "assets/i18n/messages_en.properties"
        val bundle = child.getResourceAsStream(path)!!.use {
            PropertyResourceBundle(InputStreamReader(it, Charsets.UTF_8))
        }
        assertEquals("Search", bundle.getString("search"))
        assertEquals("Résumé", bundle.getString("title"))
        assertEquals(1, child.getResources(path).toList().size)
        assertEquals(0, child.getResources("assets/missing.properties").toList().size)
        assertNull(parent.getResource(javaClass.name.replace('.', '/') + ".class"))
        assertEquals("aniyomi-asset", child.getResource(path)!!.protocol)
    }

    @Test fun resourceLookupIsScopedToOneApkAndStreamsHaveIndependentPositions() {
        val first = AniyomiApkResources().apply { readEntry("assets/a.txt", "abc".byteInputStream()) }
        val url = first.find("assets/a.txt")!!
        url.openStream().use { one ->
            assertEquals('a'.code, one.read())
            url.openStream().use { two -> assertEquals("abc", two.reader().readText()) }
            assertEquals("bc", one.reader().readText())
        }
        assertNull(AniyomiApkResources().find("assets/a.txt"))
        assertThrows(IllegalArgumentException::class.java) { URL(url, "different.txt").openStream() }
    }

    @Test fun invalidNamesDuplicateEntriesAndOversizedResourcesFailClosed() {
        val assets = AniyomiApkResources()
        for (name in listOf("../private", "/assets/a", "assets/../private", "assets/a\\b", "assets//b", "file:/private", "classes.dex")) {
            assertNull(assets.find(name))
            assertThrows(IllegalArgumentException::class.java) { assets.readEntry(name, byteArrayOf(1).inputStream()) }
        }
        assets.readEntry("assets/a", byteArrayOf(1).inputStream())
        assertThrows(IllegalArgumentException::class.java) { assets.readEntry("assets/a", byteArrayOf(2).inputStream()) }
        assertThrows(IllegalArgumentException::class.java) {
            assets.readEntry("assets/b", ByteArray(AniyomiApkResources.MAX_ENTRY_BYTES + 1).inputStream())
        }
        assertNull(assets.find("assets/b"))
    }

    @Test fun resourceCountAndTotalMemoryAreBounded() {
        val countLimited = AniyomiApkResources()
        repeat(AniyomiApkResources.MAX_ENTRIES) { countLimited.readEntry("assets/$it", byteArrayOf(1).inputStream()) }
        assertThrows(IllegalArgumentException::class.java) { countLimited.readEntry("assets/overflow", byteArrayOf(1).inputStream()) }
        val memoryLimited = AniyomiApkResources()
        repeat(AniyomiApkResources.MAX_TOTAL_BYTES / AniyomiApkResources.MAX_ENTRY_BYTES) {
            memoryLimited.readEntry("assets/$it", ByteArray(AniyomiApkResources.MAX_ENTRY_BYTES).inputStream())
        }
        assertThrows(IllegalArgumentException::class.java) { memoryLimited.readEntry("assets/overflow", byteArrayOf(1).inputStream()) }
    }
}
