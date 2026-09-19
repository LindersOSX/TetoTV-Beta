package dev.animetv.anime_tv.aniyomi

import java.io.File
import java.io.FileOutputStream

/** Approved code is app data, not disposable compiler/cache data. No backup or external storage. */
internal class AniyomiSnapshotStorage(durableRoot: File, legacyRoot: File) {
    val root = durableRoot.apply { check(isDirectory || mkdirs()) { "snapshot_storage_failed" } }.canonicalFile
    private val legacy = legacyRoot.canonicalFile

    @Synchronized
    fun resolve(hash: String): File {
        require(hash.matches(Regex("[0-9a-f]{64}"))) { "invalid_snapshot_identity" }
        val destination = File(root, "$hash.apk").canonicalFile
        require(destination.parentFile == root) { "invalid_snapshot_identity" }
        if (destination.exists()) {
            require(destination.isFile) { "snapshot_unavailable" }
            return destination // The caller re-verifies bytes, signer and approved identity.
        }
        val old = File(legacy, "$hash.apk").canonicalFile
        require(old.parentFile == legacy && old.isFile) { "snapshot_unavailable" }
        require(old.length() in 1..AniyomiPolicy.MAX_APK_BYTES.toLong()) { "invalid_apk_size" }
        val temporary = File.createTempFile("migrate-", ".apk", root)
        try {
            FileOutputStream(temporary).use { output ->
                check(temporary.setReadOnly()) { "readonly_apk_required" }
                old.inputStream().use { input ->
                    val buffer = ByteArray(32 * 1024)
                    var total = 0L
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        total += count
                        require(total <= AniyomiPolicy.MAX_APK_BYTES) { "apk_too_large" }
                        output.write(buffer, 0, count)
                    }
                }
                output.fd.sync()
            }
            require(AniyomiApkStore.sha256(temporary) == hash) { "snapshot_integrity_failed" }
            check(temporary.renameTo(destination)) { "snapshot_storage_failed" }
            // Leave the old snapshot intact. The caller must still verify the APK signature
            // and compare the complete stored approval before any extension can execute.
            return destination
        } finally {
            if (temporary.exists()) temporary.delete()
        }
    }
}
