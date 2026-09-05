package dev.animetv.anime_tv.player

import org.junit.Assert.*
import org.junit.Test

class Media3TrackIdentityRegistryTest {
    // The cache is generic; test structural equality without Android's
    // TextUtils required by Media3 Format construction. Production uses the
    // immutable TrackGroup's documented ID + Format-content equality.
    private data class Group(val id: String, val language: String, val mime: String, val label: String)
    private fun group(id: String, language: String, mime: String = "audio/mp4a-latm") =
        Group(id, language, mime, "Track")

    @Test fun recreatedGroupsKeepSelectedAudioAndCaptionIdsDespiteReversedArrival() {
        val registry = Media3TrackIdentityRegistry<Group>()
        val first = listOf(group("1", "en"), group("2", "ja"), group("3", "es", "application/x-subrip"))
        val expectedIds = first.map(registry::idFor)
        assertEquals(listOf(0, 1, 2), expectedIds)
        // The native restart has no tracks while preparing. Nothing is pruned.
        assertEquals(3, registry.size)
        val recreated = listOf(group("3", "es", "application/x-subrip"), group("2", "ja"), group("1", "en"))
        assertNotSame(first.last(), recreated.first())
        assertEquals(listOf(2, 1, 0), recreated.map(registry::idFor))
        assertEquals(expectedIds[1], registry.idFor(group("2", "ja")))
    }

    @Test fun sameLabelsAndIdsCannotAliasDifferentLanguagesOrMediaTypes() {
        val registry = Media3TrackIdentityRegistry<Group>()
        val english = registry.idFor(group("1", "en"))
        val japanese = registry.idFor(group("1", "ja"))
        val caption = registry.idFor(group("1", "en", "application/x-subrip"))
        assertNotEquals(english, japanese)
        assertNotEquals(english, caption)
    }

    @Test fun retentionIsBoundedAndEvictedIdsAreNeverReusedWithinAnOpen() {
        val registry = Media3TrackIdentityRegistry<String>(2)
        assertEquals(0, registry.idFor("english"))
        assertEquals(1, registry.idFor("japanese"))
        assertEquals(0, registry.idFor("english")) // Refresh its LRU slot.
        assertEquals(2, registry.idFor("spanish"))
        assertEquals(2, registry.size)
        assertEquals(0, registry.idFor("english"))
        assertEquals(3, registry.idFor("japanese"))
        assertEquals(2, registry.size)
        registry.clear()
        assertEquals(0, registry.size)
        assertEquals(0, registry.idFor("new-source"))
    }
}
