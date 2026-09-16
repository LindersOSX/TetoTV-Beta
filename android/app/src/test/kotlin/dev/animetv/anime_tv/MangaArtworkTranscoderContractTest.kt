package dev.animetv.anime_tv

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MangaArtworkTranscoderContractTest {
    private val transcoder by lazy { source("MangaArtworkTranscoder.kt") }
    private val activity by lazy { source("MainActivity.kt") }

    @Test
    fun `modern cover decode is dimension and byte bounded`() {
        assertTrue(transcoder.contains("MAX_ENCODED_BYTES"))
        assertTrue(transcoder.contains("MAX_OUTPUT_BYTES"))
        assertTrue(transcoder.contains("MAX_SOURCE_PIXELS"))
        assertTrue(transcoder.contains("TARGET_PIXELS"))
        assertTrue(transcoder.contains("decoder.setTargetSize"))
        assertTrue(transcoder.contains("WEBP_LOSSY"))
        assertFalse(transcoder.contains("Log."))
    }

    @Test
    fun `cover decode cannot block the Flutter platform thread`() {
        val branch = activity
            .substringAfter("\"transcodeMangaArtwork\" ->", "")
            .substringBefore("\"importMangaBackup\" ->")
        assertTrue(branch.contains("runPlatformBlockingOperation"))
        assertTrue(branch.contains("MangaArtworkTranscoder.transcode"))
        assertFalse(branch.contains("encoded.decodeToString"))
    }

    private fun source(name: String): String {
        val workingDirectory = System.getProperty("user.dir") ?: "."
        return generateSequence(File(workingDirectory)) { it.parentFile }
            .take(7)
            .map { File(it, "src/main/kotlin/dev/animetv/anime_tv/$name") }
            .firstOrNull(File::isFile)
            ?.readText()
            ?: error("Missing $name")
    }
}
