package dev.animetv.anime_tv

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.math.BigInteger
import java.security.AlgorithmParameters
import java.security.GeneralSecurityException
import java.security.InvalidKeyException
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.NoSuchAlgorithmException
import java.security.ProviderException
import java.security.SecureRandom
import java.security.interfaces.ECPrivateKey
import java.security.interfaces.ECPublicKey
import java.security.spec.ECFieldFp
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPrivateKeySpec
import java.security.spec.ECPublicKeySpec
import java.security.spec.InvalidKeySpecException
import javax.crypto.KeyAgreement

internal data class PhoneSetupP256KeyMaterial(
    val privateD: ByteArray,
    val publicX: ByteArray,
    val publicY: ByteArray,
)

/**
 * App-owned P-256 operations for the short-lived phone-setup session.
 *
 * P-256 wire values are unsigned, fixed-width 32-byte integers. Java's
 * BigInteger byte APIs are signed and variable-width, so every conversion is
 * explicit at this boundary. This avoids accepting negative peer coordinates
 * or emitting the occasional 31/33-byte component.
 */
internal object PhoneSetupP256 {
    private const val componentSize = 32
    private const val curveName = "secp256r1"
    private val two = BigInteger.valueOf(2)
    private val three = BigInteger.valueOf(3)

    private val parameters: ECParameterSpec by lazy {
        AlgorithmParameters.getInstance("EC").run {
            init(ECGenParameterSpec(curveName))
            getParameterSpec(ECParameterSpec::class.java)
        }
    }

    fun generateKeyMaterial(): PhoneSetupP256KeyMaterial {
        val generator = KeyPairGenerator.getInstance("EC")
        generator.initialize(ECGenParameterSpec(curveName), SecureRandom())
        val keyPair = generator.generateKeyPair()
        val privateKey = keyPair.private as? ECPrivateKey
            ?: throw GeneralSecurityException("The P-256 provider returned an invalid private key.")
        val publicKey = keyPair.public as? ECPublicKey
            ?: throw GeneralSecurityException("The P-256 provider returned an invalid public key.")
        return PhoneSetupP256KeyMaterial(
            privateD = encodeComponent(privateKey.s),
            publicX = encodeComponent(publicKey.w.affineX),
            publicY = encodeComponent(publicKey.w.affineY),
        )
    }

    fun deriveSharedSecret(
        privateD: ByteArray,
        localX: ByteArray,
        localY: ByteArray,
        remoteX: ByteArray,
        remoteY: ByteArray,
    ): ByteArray {
        val d = decodeComponent(privateD, "device private scalar")
        require(d.signum() > 0 && d < parameters.order) {
            "The device private scalar is outside the P-256 range."
        }

        // The local coordinates are persisted beside the scalar and published
        // to the broker. Validate their representation and curve membership so
        // corrupted restored state fails closed before key agreement.
        decodeAndValidatePoint(localX, localY, "device public key")
        val remotePoint = decodeAndValidatePoint(
            remoteX,
            remoteY,
            "browser public key",
        )

        try {
            val keyFactory = KeyFactory.getInstance("EC")
            val privateKey = keyFactory.generatePrivate(
                ECPrivateKeySpec(d, parameters),
            )
            val remotePublicKey = keyFactory.generatePublic(
                ECPublicKeySpec(remotePoint, parameters),
            )
            val agreement = KeyAgreement.getInstance("ECDH")
            agreement.init(privateKey)
            agreement.doPhase(remotePublicKey, true)
            return encodeSecret(agreement.generateSecret())
        } catch (error: InvalidKeySpecException) {
            throw IllegalArgumentException("The P-256 key material is invalid.", error)
        } catch (error: InvalidKeyException) {
            throw IllegalArgumentException("The P-256 key material is invalid.", error)
        }
    }

    private fun decodeAndValidatePoint(
        xBytes: ByteArray,
        yBytes: ByteArray,
        label: String,
    ): ECPoint {
        val x = decodeComponent(xBytes, "$label X coordinate")
        val y = decodeComponent(yBytes, "$label Y coordinate")
        val field = parameters.curve.field as? ECFieldFp
            ?: throw GeneralSecurityException("The P-256 provider did not return a prime field.")
        val prime = field.p
        require(x < prime && y < prime) { "$label is outside the P-256 field." }

        val left = y.modPow(two, prime)
        val right = x.modPow(three, prime)
            .add(parameters.curve.a.multiply(x))
            .add(parameters.curve.b)
            .mod(prime)
        require(left == right) { "$label is not on the P-256 curve." }
        return ECPoint(x, y)
    }

    private fun decodeComponent(bytes: ByteArray, label: String): BigInteger {
        require(bytes.size == componentSize) { "$label must contain 32 bytes." }
        return BigInteger(1, bytes)
    }

    private fun encodeComponent(value: BigInteger): ByteArray {
        require(value.signum() >= 0) { "P-256 values cannot be negative." }
        return encodeUnsigned(value.toByteArray())
    }

    private fun encodeSecret(value: ByteArray): ByteArray {
        require(value.isNotEmpty()) { "The P-256 shared secret is empty." }
        return encodeUnsigned(value)
    }

    private fun encodeUnsigned(encoded: ByteArray): ByteArray {
        val firstDataByte = if (
            encoded.size == componentSize + 1 && encoded.first() == 0.toByte()
        ) {
            1
        } else {
            0
        }
        val dataSize = encoded.size - firstDataByte
        require(dataSize in 1..componentSize) { "The P-256 value is too large." }
        return ByteArray(componentSize).also { output ->
            encoded.copyInto(
                destination = output,
                destinationOffset = componentSize - dataSize,
                startIndex = firstDataByte,
            )
        }
    }
}

internal object PhoneSetupP256Bridge {
    private const val generateMethod = "generatePhoneSetupP256KeyPair"
    private const val deriveMethod = "derivePhoneSetupP256SharedSecret"

    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            generateMethod -> generate(result)
            deriveMethod -> derive(call, result)
            else -> return false
        }
        return true
    }

    private fun generate(result: MethodChannel.Result) {
        try {
            val key = PhoneSetupP256.generateKeyMaterial()
            result.success(
                mapOf(
                    "d" to key.privateD,
                    "x" to key.publicX,
                    "y" to key.publicY,
                ),
            )
        } catch (_: GeneralSecurityException) {
            result.error(
                "PHONE_SETUP_CRYPTO_UNAVAILABLE",
                "Secure P-256 key generation is unavailable on this device.",
                null,
            )
        } catch (_: IllegalArgumentException) {
            result.error(
                "PHONE_SETUP_CRYPTO_OUTPUT",
                "Android returned invalid P-256 key material.",
                null,
            )
        } catch (_: ProviderException) {
            result.error(
                "PHONE_SETUP_CRYPTO_UNAVAILABLE",
                "Secure P-256 key generation is unavailable on this device.",
                null,
            )
        }
    }

    private fun derive(call: MethodCall, result: MethodChannel.Result) {
        try {
            val secret = PhoneSetupP256.deriveSharedSecret(
                privateD = requiredBytes(call, "privateD"),
                localX = requiredBytes(call, "localX"),
                localY = requiredBytes(call, "localY"),
                remoteX = requiredBytes(call, "remoteX"),
                remoteY = requiredBytes(call, "remoteY"),
            )
            result.success(secret)
        } catch (_: IllegalArgumentException) {
            result.error(
                "PHONE_SETUP_CRYPTO_INPUT",
                "The phone-setup P-256 key material is invalid.",
                null,
            )
        } catch (_: NoSuchAlgorithmException) {
            result.error(
                "PHONE_SETUP_CRYPTO_UNAVAILABLE",
                "Secure P-256 key agreement is unavailable on this device.",
                null,
            )
        } catch (_: GeneralSecurityException) {
            result.error(
                "PHONE_SETUP_CRYPTO_UNAVAILABLE",
                "Secure P-256 key agreement failed on this device.",
                null,
            )
        } catch (_: ProviderException) {
            result.error(
                "PHONE_SETUP_CRYPTO_UNAVAILABLE",
                "Secure P-256 key agreement failed on this device.",
                null,
            )
        }
    }

    private fun requiredBytes(call: MethodCall, name: String): ByteArray {
        val value: Any? = call.argument<Any>(name)
        return (value as? ByteArray)?.copyOf()
            ?: throw IllegalArgumentException("The $name value is missing or invalid.")
    }
}
