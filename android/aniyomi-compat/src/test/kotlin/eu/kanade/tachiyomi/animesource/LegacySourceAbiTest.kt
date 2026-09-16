package eu.kanade.tachiyomi.animesource

import eu.kanade.tachiyomi.animesource.model.Hoster
import eu.kanade.tachiyomi.animesource.model.SEpisode
import eu.kanade.tachiyomi.animesource.model.SerializableHoster
import eu.kanade.tachiyomi.animesource.model.SerializableVideo
import eu.kanade.tachiyomi.animesource.online.AnimeHttpSource
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LegacySourceAbiTest {
    @Test
    fun preMemoSerializableVideoDescriptorsRemainCallable() {
        val valueTypes = videoValueTypes()
        val oldConstructor = SerializableVideo::class.java.getDeclaredConstructor(*valueTypes)
        val oldDefaultConstructor = SerializableVideo::class.java.getDeclaredConstructor(
            *valueTypes,
            Int::class.javaPrimitiveType,
            Class.forName("kotlin.jvm.internal.DefaultConstructorMarker"),
        )
        SerializableVideo::class.java.getDeclaredConstructor(
            Int::class.javaPrimitiveType,
            *valueTypes,
            Class.forName("kotlinx.serialization.internal.SerializationConstructorMarker"),
        )
        SerializableVideo::class.java.getDeclaredMethod("copy", *valueTypes)
        SerializableVideo::class.java.getDeclaredMethod(
            "copy\$default",
            SerializableVideo::class.java,
            *valueTypes,
            Int::class.javaPrimitiveType,
            Any::class.java,
        )

        val oldValue = oldConstructor.newInstance(*videoValues()) as SerializableVideo
        assertEquals("https://example.test/video.m3u8", oldValue.videoUrl)
        assertTrue(oldValue.memo.isEmpty())

        val defaults = oldDefaultConstructor.newInstance(
            *arrayOfNulls<Any?>(5),
            false,
            *arrayOfNulls<Any?>(7),
            false,
            0x3fff,
            null,
        ) as SerializableVideo
        assertEquals("", defaults.videoUrl)
        assertEquals(emptyList<Any>(), defaults.subtitleTracks)
        assertTrue(defaults.memo.isEmpty())
    }

    @Test
    fun preMemoSerializableHosterDescriptorsRemainCallable() {
        val valueTypes = hosterValueTypes()
        val oldConstructor = SerializableHoster::class.java.getDeclaredConstructor(*valueTypes)
        val oldDefaultConstructor = SerializableHoster::class.java.getDeclaredConstructor(
            *valueTypes,
            Int::class.javaPrimitiveType,
            Class.forName("kotlin.jvm.internal.DefaultConstructorMarker"),
        )
        SerializableHoster::class.java.getDeclaredConstructor(
            Int::class.javaPrimitiveType,
            *valueTypes,
            Class.forName("kotlinx.serialization.internal.SerializationConstructorMarker"),
        )
        SerializableHoster::class.java.getDeclaredMethod("copy", *valueTypes)
        SerializableHoster::class.java.getDeclaredMethod(
            "copy\$default",
            SerializableHoster::class.java,
            *valueTypes,
            Int::class.javaPrimitiveType,
            Any::class.java,
        )

        val oldValue = oldConstructor.newInstance("https://example.test", "Fixture", null, "", false)
            as SerializableHoster
        assertEquals("Fixture", oldValue.hosterName)
        assertTrue(oldValue.memo.isEmpty())

        val defaults = oldDefaultConstructor.newInstance(null, null, null, null, false, 0x1f, null)
            as SerializableHoster
        assertEquals("", defaults.hosterUrl)
        assertTrue(defaults.memo.isEmpty())
    }

    @Test
    fun preMemoHosterCopyAndApi14VirtualSlotRemain() {
        val valueTypes = hosterValueTypes().also { it[2] = List::class.java }
        Hoster::class.java.getDeclaredMethod("copy", *valueTypes)
        Hoster::class.java.getDeclaredMethod(
            "copy\$default",
            Hoster::class.java,
            *valueTypes,
            Int::class.javaPrimitiveType,
            Any::class.java,
        )
        val episodeParser = AnimeHttpSource::class.java.getDeclaredMethod(
            "episodeVideoParse",
            okhttp3.Response::class.java,
        )
        assertEquals(SEpisode::class.java, episodeParser.returnType)
    }

    private fun videoValueTypes(): Array<Class<*>> = arrayOf(
        String::class.java,
        String::class.java,
        Integer::class.java,
        Integer::class.java,
        List::class.java,
        Boolean::class.javaPrimitiveType!!,
        List::class.java,
        List::class.java,
        List::class.java,
        List::class.java,
        List::class.java,
        List::class.java,
        String::class.java,
        Boolean::class.javaPrimitiveType!!,
    )

    private fun videoValues(): Array<Any?> = arrayOf(
        "https://example.test/video.m3u8",
        "1080p",
        1080,
        4_000_000,
        null,
        true,
        emptyList<Any>(),
        emptyList<Any>(),
        emptyList<Any>(),
        emptyList<Any>(),
        emptyList<Any>(),
        emptyList<Any>(),
        "",
        true,
    )

    private fun hosterValueTypes(): Array<Class<*>> = arrayOf(
        String::class.java,
        String::class.java,
        String::class.java,
        String::class.java,
        Boolean::class.javaPrimitiveType!!,
    )
}
