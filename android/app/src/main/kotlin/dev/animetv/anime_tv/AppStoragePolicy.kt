package dev.animetv.anime_tv

import java.io.File

/** Scoped deletion policy for the non-destructive Clear cache action. */
object AppStoragePolicy {
    fun clearCacheRoots(roots: Iterable<File>): Long {
        val distinctRoots = roots.distinctBy { root ->
            runCatching { root.canonicalPath }.getOrElse { root.absolutePath }
        }
        var removedBytes = 0L
        distinctRoots.forEach { root ->
            val canonicalRoot = runCatching { root.canonicalFile }.getOrNull() ?: return@forEach
            canonicalRoot.listFiles()?.forEach { child ->
                removedBytes += deleteCacheEntry(child, canonicalRoot)
            }
        }
        return removedBytes
    }

    private fun deleteCacheEntry(entry: File, canonicalRoot: File): Long {
        val canonicalEntry = runCatching { entry.canonicalFile }.getOrNull() ?: return 0L
        val rootPrefix = canonicalRoot.path + File.separator
        if (!canonicalEntry.path.startsWith(rootPrefix)) return 0L
        val bytes = if (canonicalEntry.isFile) {
            canonicalEntry.length()
        } else {
            canonicalEntry.listFiles()?.sumOf { deleteCacheEntry(it, canonicalEntry) } ?: 0L
        }
        return if (runCatching { canonicalEntry.delete() }.getOrDefault(false)) bytes else 0L
    }
}
