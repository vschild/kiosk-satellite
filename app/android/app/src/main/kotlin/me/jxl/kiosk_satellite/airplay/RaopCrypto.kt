package me.jxl.kiosk_satellite.airplay

import android.util.Base64
import java.math.BigInteger
import java.net.Inet4Address
import java.net.InetAddress
import java.security.KeyFactory
import java.security.interfaces.RSAPrivateCrtKey
import java.security.spec.RSAPrivateCrtKeySpec
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * The cryptography of AirPlay 1 (RAOP) on the receiving side, all of it
 * keyed by the AirPort Express private key that every AirPlay 1 receiver
 * outside Apple's own has used since it was published in 2011.
 *
 *  - The sender proves it talks to an AirPlay speaker with an
 *    Apple-Challenge header: the receiver signs the challenge, its own
 *    address and its hardware address with the key ([challengeResponse]).
 *  - The ANNOUNCE carries the stream's AES key wrapped in RSA-OAEP under
 *    the key's public half ([unwrapAesKey]).
 *  - Every audio packet's payload is AES-128-CBC, the IV restarting at
 *    each packet and a tail shorter than a block left in the clear
 *    ([PacketCipher]).
 */
internal object RaopCrypto {
    /** PKCS#1 DER of the AirPort Express key, base64. */
    private const val AIRPORT_KEY =
        "MIIEpQIBAAKCAQEA59dE8qLieItsH1WgjrcFRKj6eUWqi+bGLOX1HL3U3GhC/j0Qg90u3sG/1CUt" +
            "wC5vOYvfDmFI6oSFXi5ELabWJmT2dKHzBJKa3k9ok+8t9ucRqMd6DZHJ2YCCLlDRKSKv6kDqnw4U" +
            "wPdpOMXziC/AMj3Z/lUVX1G7WSHCAWKf1zNS1eLvqr+boEjXuBOitnZ/bDzPHrTOZz0Dew0uowxf" +
            "/+sG+NCK3eQJVxqcaJ/vEHKIVd2M+5qL71yJQ+87X6oV3eaYvt3zWZYD6z5vYTcrtij2VZ9Zmni/" +
            "UAaHqn9JdsBWLUEpVviYnhimNVvYFZeCXg/IdTQ+x4IRdiXNv5hEewIDAQABAoIBAQDl8Axy9XfW" +
            "BLmkzkEiqoSwF0PsmVrPzH9KsnwLGH+QZlvjWd8SWYGN7u1507HvhF5N3drJoVU3O14nDY4TFQAa" +
            "LlJ9VM35AApXaLyY1ERrN7u9ALKd2LUwYhM7Km539O4yUFYikE2nIPscEsA5ltpxOgUGCY7b7ez5" +
            "NtD6nL1ZKauw7aNXmVAvmJTcuPxWmoktF3gDJKK2wxZuNGcJE0uFQEG4Z3BrWP7yoNuSK3dii2jm" +
            "lpPHr0O/KnPQtzI3eguhe0TwUem/eYSdyzMyVx/YpwkzwtYL3sR5k0o9rKQLtvLzfAqdBxBurciz" +
            "aaA/L0HIgAmOit1GJA2saMxTVPNhAoGBAPfgv1oeZxgxmotiCcMXFEQEWflzhWYTsXrhUIuz5jFu" +
            "a39GLS99ZEErhLdrwj8rDDViRVJ5skOp9zFvlYAHs0xh92ji1E7V/ysnKBfsMrPkk5KSKPrnjndM" +
            "oPdevWnVkgJ5jxFuNgxkOLMuG9i53B4yMvDTCRiIPMQ++N2iLDaRAoGBAO9v//mU8eVkQaoANf0Z" +
            "oMjW8CN4xwWA2cSEIHkd9AfFkftuv8oyLDCG3ZAf0vrhrrtkrfa7ef+AUb69DNggq4mHQAYBp7L+" +
            "k5DKzJrKuO0r+R0YbY9pZD1+/g9dVt91d6LQNepUE/yY2PP5CNoFmjedpLHMOPFdVgqDzDFxU8hL" +
            "AoGBANDrr7xAJbqBjHVwIzQ4To9pb4BNeqDndk5Qe7fT3+/H1njGaC0/rXE0Qb7q5ySgnsCb3DvA" +
            "cJyRM9SJ7OKlGt0FMSdJD5KG0XPIpAVNwgpXXH5MDJg09KHeh0kXo+QA6viFBi21y340NonnEfdf" +
            "54PX4ZGS/Xac1UK+pLkBB+zRAoGAf0AY3H3qKS2lMEI4bzEFoHeK3G895pDaK3TFBVmD7fV0Zhov" +
            "17fegFPMwOII8MisYm9ZfT2Z0s5Ro3s5rkt+nvLAdfC/PYPKzTLalpGSwomSNYJcB9HNMlmhkGzc" +
            "1JnLYT4iyUyx6pcZBmCd8bD0iwY/FzcgNDaUmbX9+XDvRA0CgYEAkE7pIPlE71qvfJQgoA9em0gI" +
            "LAuE4Pu13aKiJnfft7hIjbK+5kyb3TysZvoyDnb3HOKvInK7vXbKuU4ISgxB2bB3HcYzQMGsz1qJ" +
            "2gG0N5hvJpzwwhbhXqFKA4zaaSrw622wDniAK5MlIE0tIAKKP4yxNGjoD2QYjhBGuhvkWKY="

    private val key: RSAPrivateCrtKey by lazy {
        val der = Base64.decode(AIRPORT_KEY, Base64.DEFAULT)
        val ints = Der(der).sequenceOfIntegers()
        // version, n, e, d, p, q, dp, dq, qinv
        val spec = RSAPrivateCrtKeySpec(
            ints[1], ints[2], ints[3], ints[4], ints[5], ints[6], ints[7], ints[8],
        )
        KeyFactory.getInstance("RSA").generatePrivate(spec) as RSAPrivateCrtKey
    }

    /**
     * The Apple-Response for an Apple-Challenge: the challenge, the
     * address the sender reached us on and our hardware address, padded
     * to 32 bytes, signed with PKCS#1 v1.5 block type 1, base64 without
     * the trailing padding.
     */
    fun challengeResponse(challenge: String, local: InetAddress, hardware: ByteArray): String? {
        val raw = runCatching { Base64.decode(challenge.trim(), Base64.DEFAULT) }.getOrNull()
            ?: return null
        if (raw.size > 16) return null
        val address = if (local is Inet4Address) local.address else local.address.copyOf(16)
        var data = raw + address + hardware
        if (data.size < 32) data = data.copyOf(32)
        val k = (key.modulus.bitLength() + 7) / 8
        // 00 01 FF..FF 00 data
        val block = ByteArray(k) { 0xFF.toByte() }
        block[0] = 0
        block[1] = 1
        block[k - data.size - 1] = 0
        System.arraycopy(data, 0, block, k - data.size, data.size)
        val signed = BigInteger(1, block).modPow(key.privateExponent, key.modulus)
        val bytes = unsigned(signed, k)
        return Base64.encodeToString(bytes, Base64.NO_WRAP).trimEnd('=')
    }

    /** The stream's AES key from the ANNOUNCE's `a=rsaaeskey`. */
    fun unwrapAesKey(wrapped: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("RSA/ECB/OAEPWithSHA-1AndMGF1Padding")
        cipher.init(Cipher.DECRYPT_MODE, key)
        return cipher.doFinal(wrapped)
    }

    /** Decrypts audio payloads in place, one packet at a time. */
    class PacketCipher(aesKey: ByteArray, private val iv: ByteArray) {
        private val keySpec = SecretKeySpec(aesKey, "AES")
        private val cipher = Cipher.getInstance("AES/CBC/NoPadding")

        fun decrypt(buf: ByteArray, offset: Int, length: Int) {
            val whole = length and 15.inv()
            if (whole == 0) return
            cipher.init(Cipher.DECRYPT_MODE, keySpec, IvParameterSpec(iv))
            cipher.doFinal(buf, offset, whole, buf, offset)
        }
    }

    private fun unsigned(v: BigInteger, size: Int): ByteArray {
        val b = v.toByteArray()
        return when {
            b.size == size -> b
            b.size > size -> b.copyOfRange(b.size - size, b.size)
            else -> ByteArray(size - b.size) + b
        }
    }

    /** Just enough DER to read a SEQUENCE of INTEGERs. */
    private class Der(private val buf: ByteArray) {
        private var pos = 0

        fun sequenceOfIntegers(): List<BigInteger> {
            expect(0x30)
            val end = length() + pos
            val out = ArrayList<BigInteger>()
            while (pos < end) {
                expect(0x02)
                val n = length()
                out.add(BigInteger(buf.copyOfRange(pos, pos + n)))
                pos += n
            }
            return out
        }

        private fun expect(tag: Int) {
            check(buf[pos++].toInt() and 0xFF == tag) { "bad key" }
        }

        private fun length(): Int {
            val first = buf[pos++].toInt() and 0xFF
            if (first < 0x80) return first
            var n = 0
            repeat(first and 0x7F) { n = (n shl 8) or (buf[pos++].toInt() and 0xFF) }
            return n
        }
    }
}
