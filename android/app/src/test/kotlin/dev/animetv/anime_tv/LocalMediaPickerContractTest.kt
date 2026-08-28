package dev.animetv.anime_tv

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LocalMediaPickerContractTest {
    private val mainActivity by lazy {
        source("main/kotlin/dev/animetv/anime_tv/MainActivity.kt").readText()
    }

    @Test
    fun `picker grants only scoped persistent read access`() {
        val picker = mainActivity
            .substringAfter("private fun pickLocalVideo", "")
            .substringBefore("private fun localMediaMetadata")

        assertTrue(picker.contains("Intent.ACTION_OPEN_DOCUMENT"))
        assertTrue(picker.contains("Intent.CATEGORY_OPENABLE"))
        assertTrue(picker.contains("FLAG_GRANT_READ_URI_PERMISSION"))
        assertTrue(picker.contains("FLAG_GRANT_PERSISTABLE_URI_PERMISSION"))
        assertTrue(picker.contains("type = \"video/*\""))
        assertFalse(picker.contains("FLAG_GRANT_WRITE_URI_PERMISSION"))
    }

    @Test
    fun `manifest does not request broad media or storage access`() {
        val manifest = source("main/AndroidManifest.xml").readText()

        assertFalse(manifest.contains("READ_EXTERNAL_STORAGE"))
        assertFalse(manifest.contains("WRITE_EXTERNAL_STORAGE"))
        assertFalse(manifest.contains("MANAGE_EXTERNAL_STORAGE"))
        assertFalse(manifest.contains("READ_MEDIA_VIDEO"))
    }

    @Test
    fun `activity destruction completes a pending picker call`() {
        val onDestroy = mainActivity
            .substringAfter("override fun onDestroy()", "")
            .substringBefore("companion object")

        assertTrue(onDestroy.contains("pendingLocalMediaResult?.error"))
        assertTrue(onDestroy.contains("pendingLocalMediaResult = null"))
    }

    @Test
    fun `picker result validates content URI before provider metadata access`() {
        val resultHandler = mainActivity
            .substringAfter("override fun onActivityResult", "")
            .substringBefore("if (requestCode == VOICE_SEARCH_REQUEST_CODE)")
        val validationIndex = resultHandler.indexOf("uri.scheme")
        val metadataIndex = resultHandler.indexOf("localMediaMetadata(uri")

        assertTrue(validationIndex >= 0)
        assertTrue(resultHandler.contains("SCHEME_CONTENT") || resultHandler.contains("\"content\""))
        assertTrue(resultHandler.contains("uri.authority.isNullOrBlank()"))
        assertTrue(resultHandler.contains("uri.userInfo != null"))
        assertTrue(resultHandler.contains("uri.fragment != null"))
        assertTrue(metadataIndex > validationIndex)
    }

    @Test
    fun `provider metadata failure returns a bounded channel error instead of crashing`() {
        val resultHandler = mainActivity
            .substringAfter("override fun onActivityResult", "")
            .substringBefore("if (requestCode == VOICE_SEARCH_REQUEST_CODE)")

        assertTrue(resultHandler.contains("localMediaMetadata(uri"))
        assertTrue(
            resultHandler.contains("LOCAL_MEDIA_METADATA") ||
                resultHandler.contains("LOCAL_MEDIA_PICKER_RESULT"),
        )
        assertTrue(resultHandler.contains("pending.error"))
    }

    @Test
    fun `choosing a new file releases stale persisted read grants`() {
        val resultHandler = mainActivity
            .substringAfter("override fun onActivityResult", "")
            .substringBefore("if (requestCode == VOICE_SEARCH_REQUEST_CODE)")

        assertTrue(resultHandler.contains("persistedUriPermissions"))
        assertTrue(resultHandler.contains("permission.uri != uri"))
        assertTrue(resultHandler.contains("releasePersistableUriPermission"))
        assertTrue(resultHandler.contains("hasReadGrant"))
        val persistCall = resultHandler
            .substringAfter("takePersistableUriPermission(", "")
            .substringBefore(")")
        assertTrue(persistCall.contains("Intent.FLAG_GRANT_READ_URI_PERMISSION"))
        assertFalse(resultHandler.contains("FLAG_GRANT_WRITE_URI_PERMISSION"))
    }

    @Test
    fun `failed replacement keeps the previous durable grant`() {
        val resultHandler = mainActivity
            .substringAfter("override fun onActivityResult", "")
            .substringBefore("if (requestCode == VOICE_SEARCH_REQUEST_CODE)")

        val metadataIndex = resultHandler.indexOf("localMediaMetadata(uri")
        val persistIndex = resultHandler.indexOf("takePersistableUriPermission(")
        val releaseIndex = resultHandler.indexOf("releasePersistableUriPermission(")

        assertTrue(metadataIndex >= 0)
        assertTrue(persistIndex > metadataIndex)
        assertTrue(releaseIndex > persistIndex)
        assertTrue(resultHandler.contains("if (persistedReadPermission)"))
    }

    private fun source(relativePath: String): File {
        val workingDirectory = System.getProperty("user.dir") ?: "."
        return generateSequence(File(workingDirectory)) { it.parentFile }
            .take(7)
            .flatMap { directory ->
                sequenceOf(
                    File(directory, "src/$relativePath"),
                    File(directory, "app/src/$relativePath"),
                    File(directory, "android/app/src/$relativePath"),
                )
            }
            .firstOrNull(File::isFile)
            ?: error("Missing Android source: $relativePath")
    }
}
