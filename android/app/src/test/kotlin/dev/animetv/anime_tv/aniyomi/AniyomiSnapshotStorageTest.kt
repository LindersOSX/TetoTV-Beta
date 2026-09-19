package dev.animetv.anime_tv.aniyomi

import java.io.File
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class AniyomiSnapshotStorageTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test fun legacySnapshotMigratesWithoutChangingBytesAndSurvivesCacheEviction() {
        val legacy = temporary.newFolder("code-cache")
        val durable = temporary.newFolder("no-backup")
        val bytes = "first-party immutable snapshot fixture".toByteArray()
        val hash = AniyomiApkStore.digest(bytes)
        val old = File(legacy, "$hash.apk").apply { writeBytes(bytes); setReadOnly() }
        val migrated = AniyomiSnapshotStorage(durable, legacy).resolve(hash)
        assertEquals(durable.canonicalFile, migrated.parentFile)
        assertArrayEquals(bytes, migrated.readBytes())
        assertTrue(old.exists())
        assertTrue(old.delete()) // Model Android clearing the old compiler cache after update.
        assertArrayEquals(bytes, AniyomiSnapshotStorage(durable, legacy).resolve(hash).readBytes())
    }

    @Test fun missingFileDoesNotBecomeAnEmptyOrApprovedSnapshot() {
        val storage = AniyomiSnapshotStorage(temporary.newFolder(), temporary.newFolder())
        val failure = assertThrows(IllegalArgumentException::class.java) { storage.resolve("a".repeat(64)) }
        assertEquals("snapshot_unavailable", failure.message)
        assertEquals(0, storage.root.listFiles()!!.size)
    }

    @Test fun tamperedLegacySnapshotIsNotMigratedAndOriginalIsRetained() {
        val legacy = temporary.newFolder()
        val storage = AniyomiSnapshotStorage(temporary.newFolder(), legacy)
        val old = File(legacy, "${"b".repeat(64)}.apk").apply { writeText("wrong bytes") }
        val failure = assertThrows(IllegalArgumentException::class.java) { storage.resolve("b".repeat(64)) }
        assertEquals("snapshot_integrity_failed", failure.message)
        assertTrue(old.isFile)
        assertEquals(0, storage.root.listFiles()!!.size)
    }

    @Test fun snapshotIdentityCannotEscapeItsPrivateDirectory() {
        val storage = AniyomiSnapshotStorage(temporary.newFolder(), temporary.newFolder())
        for (value in listOf("../escape", "A".repeat(64), "a".repeat(63), "a".repeat(64) + "/x")) {
            assertThrows(IllegalArgumentException::class.java) { storage.resolve(value) }
        }
    }
}
