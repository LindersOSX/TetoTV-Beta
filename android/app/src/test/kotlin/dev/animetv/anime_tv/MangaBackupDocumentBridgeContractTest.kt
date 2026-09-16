package dev.animetv.anime_tv

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MangaBackupDocumentBridgeContractTest {
    private fun source(): String = generateSequence(File(System.getProperty("user.dir") ?: ".")) { it.parentFile }
        .take(7).flatMap { directory -> sequenceOf(
            File(directory, "src/main/kotlin/dev/animetv/anime_tv/MainActivity.kt"),
            File(directory, "app/src/main/kotlin/dev/animetv/anime_tv/MainActivity.kt"),
            File(directory, "android/app/src/main/kotlin/dev/animetv/anime_tv/MainActivity.kt"),
        ) }.first(File::isFile).readText()

    @Test
    fun `backup uses transient document grants and background bounded streams`() {
        val backup = source().substringAfter("private fun startMangaBackupPicker").substringBefore("private fun openExternalWebPage")
        assertTrue(backup.contains("Intent.ACTION_CREATE_DOCUMENT"))
        assertTrue(backup.contains("Intent.ACTION_OPEN_DOCUMENT"))
        assertTrue(backup.contains("Intent.CATEGORY_OPENABLE"))
        assertTrue(backup.contains("pendingMangaBackup != null"))
        assertTrue(backup.contains("platformBlockingExecutor.execute"))
        assertTrue(backup.contains("MangaBackupDocumentCodec::readUtf8"))
        assertTrue(backup.contains("platformResultHandler.post"))
        assertFalse(backup.contains("PERSISTABLE_URI_PERMISSION"))
        assertFalse(backup.contains("error.message"))
        assertFalse(backup.contains("Log."))
        assertFalse(backup.contains("takePersistableUriPermission"))
    }
}
