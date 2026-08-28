package dev.animetv.anime_tv

import java.math.BigInteger
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class PhoneSetupP256Test {
    @Test
    fun generatedComponentsAreAlwaysUnsignedFixedWidth() {
        var sawHighBitComponent = false
        repeat(96) {
            val key = PhoneSetupP256.generateKeyMaterial()
            assertEquals(32, key.privateD.size)
            assertEquals(32, key.publicX.size)
            assertEquals(32, key.publicY.size)
            sawHighBitComponent = sawHighBitComponent ||
                key.privateD.first().toInt() and 0x80 != 0 ||
                key.publicX.first().toInt() and 0x80 != 0 ||
                key.publicY.first().toInt() and 0x80 != 0
        }
        assertTrue("The sample should exercise unsigned high-bit values.", sawHighBitComponent)
    }

    @Test
    fun sharedSecretMatchesInBothDirectionsIncludingHighBitCoordinates() {
        val alice = PhoneSetupP256.generateKeyMaterial()
        var bob = PhoneSetupP256.generateKeyMaterial()
        repeat(256) {
            if (
                bob.publicX.first().toInt() and 0x80 != 0 ||
                bob.publicY.first().toInt() and 0x80 != 0
            ) return@repeat
            bob = PhoneSetupP256.generateKeyMaterial()
        }
        assertTrue(
            "The peer fixture should exercise an unsigned high-bit coordinate.",
            bob.publicX.first().toInt() and 0x80 != 0 ||
                bob.publicY.first().toInt() and 0x80 != 0,
        )

        val aliceSecret = PhoneSetupP256.deriveSharedSecret(
            privateD = alice.privateD,
            localX = alice.publicX,
            localY = alice.publicY,
            remoteX = bob.publicX,
            remoteY = bob.publicY,
        )
        val bobSecret = PhoneSetupP256.deriveSharedSecret(
            privateD = bob.privateD,
            localX = bob.publicX,
            localY = bob.publicY,
            remoteX = alice.publicX,
            remoteY = alice.publicY,
        )

        assertEquals(32, aliceSecret.size)
        assertArrayEquals(aliceSecret, bobSecret)
    }

    @Test
    fun rejectsNonCanonicalComponentsBeforeKeyAgreement() {
        val local = PhoneSetupP256.generateKeyMaterial()
        val remote = PhoneSetupP256.generateKeyMaterial()

        assertThrows(IllegalArgumentException::class.java) {
            PhoneSetupP256.deriveSharedSecret(
                privateD = local.privateD.copyOf(31),
                localX = local.publicX,
                localY = local.publicY,
                remoteX = remote.publicX,
                remoteY = remote.publicY,
            )
        }
        assertThrows(IllegalArgumentException::class.java) {
            PhoneSetupP256.deriveSharedSecret(
                privateD = ByteArray(32),
                localX = local.publicX,
                localY = local.publicY,
                remoteX = remote.publicX,
                remoteY = remote.publicY,
            )
        }
        val curveOrder = BigInteger(
            "FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551",
            16,
        ).toByteArray().takeLast(32).toByteArray()
        assertThrows(IllegalArgumentException::class.java) {
            PhoneSetupP256.deriveSharedSecret(
                privateD = curveOrder,
                localX = local.publicX,
                localY = local.publicY,
                remoteX = remote.publicX,
                remoteY = remote.publicY,
            )
        }
    }

    @Test
    fun rejectsOffCurveAndOutOfFieldBrowserPoints() {
        val local = PhoneSetupP256.generateKeyMaterial()

        assertThrows(IllegalArgumentException::class.java) {
            PhoneSetupP256.deriveSharedSecret(
                privateD = local.privateD,
                localX = local.publicX,
                localY = local.publicY,
                remoteX = ByteArray(32),
                remoteY = ByteArray(32),
            )
        }
        assertThrows(IllegalArgumentException::class.java) {
            PhoneSetupP256.deriveSharedSecret(
                privateD = local.privateD,
                localX = local.publicX,
                localY = local.publicY,
                remoteX = ByteArray(32) { 0xff.toByte() },
                remoteY = ByteArray(32) { 0xff.toByte() },
            )
        }
    }
}
