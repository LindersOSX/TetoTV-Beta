package dev.animetv.anime_tv.player

import com.alexmercerind.media_kit_video.FireTvSurfaceProducer
import org.junit.Assert.*
import org.junit.Test

class FireTvSurfacePolicyTest {
    @Test fun onlyTheObservedFireOsModelChangesItsMpvSurfacePath() {
        assertTrue(FireTvSurfaceProducer.needsCompatibility("Amazon", "AFTKRT", 30))
        assertTrue(FireTvSurfaceProducer.needsCompatibility("amazon", "aftkrt", 30))
        for (sdk in listOf(24, 28, 29, 31, 35, 36)) {
            assertFalse(FireTvSurfaceProducer.needsCompatibility("Amazon", "AFTKRT", sdk))
        }
        assertFalse(FireTvSurfaceProducer.needsCompatibility("Amazon", "AFTMM", 30))
        assertFalse(FireTvSurfaceProducer.needsCompatibility("Google", "AFTKRT", 30))
        assertFalse(FireTvSurfaceProducer.needsCompatibility("Amazon", "Fire tablet", 30))
    }
}
