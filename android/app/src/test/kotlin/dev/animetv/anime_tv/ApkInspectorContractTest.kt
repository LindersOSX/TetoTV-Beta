package dev.animetv.anime_tv

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

class ApkInspectorContractTest {
    @Test
    fun `archive version name is returned to the Dart verifier`() {
        val inspector = mainActivitySource()
            .substringAfter("private fun inspectApk", "")
            .substringBefore("private fun packageVersionCode")

        assertTrue(inspector.contains("val archiveVersionName = archive.versionName.orEmpty()"))
        assertTrue(inspector.contains("\"versionName\" to archiveVersionName"))
        assertTrue(inspector.contains("\"installedVersionCode\" to installedVersion"))
        assertTrue(inspector.contains("\"installedVersionName\" to installedVersionName"))
        assertTrue(inspector.contains("\"version_downgrade\""))
    }

    private fun mainActivitySource(): String {
        val workingDirectory = System.getProperty("user.dir") ?: "."
        val source = generateSequence(File(workingDirectory)) { it.parentFile }
            .take(7)
            .flatMap { directory ->
                sequenceOf(
                    File(directory, "src/main/kotlin/dev/animetv/anime_tv/MainActivity.kt"),
                    File(directory, "app/src/main/kotlin/dev/animetv/anime_tv/MainActivity.kt"),
                    File(directory, "android/app/src/main/kotlin/dev/animetv/anime_tv/MainActivity.kt"),
                )
            }
            .firstOrNull(File::isFile)
            ?: error("Missing MainActivity.kt")
        return source.readText()
    }
}
