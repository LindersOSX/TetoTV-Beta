package dev.animetv.anime_tv

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class OfflineDownloadLeasePolicyTest {
    @Test
    fun acceptsOnlyBoundedOpaqueLeaseIds() {
        assertEquals("offline-12", OfflineDownloadLeasePolicy.normalize(" offline-12 "))
        assertNull(OfflineDownloadLeasePolicy.normalize(""))
        assertNull(OfflineDownloadLeasePolicy.normalize("episode title / private path"))
        assertNull(OfflineDownloadLeasePolicy.normalize("a".repeat(97)))
    }
}
