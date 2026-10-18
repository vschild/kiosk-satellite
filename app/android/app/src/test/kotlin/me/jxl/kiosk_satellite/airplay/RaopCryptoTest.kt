package me.jxl.kiosk_satellite.airplay

import android.app.Application
import android.util.Base64
import java.net.InetAddress
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Reference values from openssl with the same key (pkeyutl, enc). */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], application = Application::class)
class RaopCryptoTest {
    @Test
    fun signsTheChallengeLikeOpenssl() {
        val challenge = Base64.encodeToString(ByteArray(16) { it.toByte() }, Base64.NO_WRAP)
        val response = RaopCrypto.challengeResponse(
            challenge,
            InetAddress.getByAddress(byteArrayOf(192.toByte(), 168.toByte(), 1, 5)),
            hex("a1b2c3d4e5f6"),
        )
        assertEquals(
            "fpBYB5x7YJsxy0CaREvMHRcp9B4W9WB8pt1TxF73zIjquG8O5fFdv86dJCGeMPXQfuYvuUIuIwpMUOFagf7VI7T8" +
                "auO3LGl3CljbNfwP/wKiGWgYM+vqAwEUE6BeBnLOjRuUyVLjQHQYKWvBXkYPy8uDsnrtP9wbyWDBhBIHSdMg" +
                "cx8hD5svGzBo0V7DxcwY3ofDfxxEiMqa/RPYmme88CjqeuJpGBXfKvQIUfqfkqES1L4talF2XxhaToaXeA+2" +
                "7L4DfFfyUgWPQdDPuJDqOHk4M6eGgn3swg9MIGR18amkQOZOcxREUXrKHT07RgrDeowQMqBM3Jhrfo0vZzxGug",
            response,
        )
    }

    @Test
    fun refusesAnOversizedChallenge() {
        val challenge = Base64.encodeToString(ByteArray(17), Base64.NO_WRAP)
        assertNull(RaopCrypto.challengeResponse(challenge, InetAddress.getLoopbackAddress(), ByteArray(6)))
    }

    @Test
    fun unwrapsTheStreamKey() {
        val wrapped = Base64.decode(
            "58ZxR5E2QhFdFxpNBvqiQZRyukG3xx3XOefS+kIXlbqKdGjVmFYtBbTnkb9T4nPUETNKcNjGOyIMXes/bHXIAQAm" +
                "RHMgLXRqNPB72yJrCw8M9LMHIDP5kmhBviKmGjzvBrp0u3TRLGxV+jguNTbj03r3KFIlbi+2K7Fn/cIL54DK" +
                "f+tZX0M0QTNuGwjfJU2PZdzORHSkp/PbO/ietfppH3wgBCrbdj7kCHBAjBjlUzPTpxHbwob6+VQWCKtnRtXk" +
                "5vddPivH3LBm/b9KtaCgejW6oeCFMSXH2jsC3qAFOav5MC/+DMma/9SU/NY0KFD5qyy/ZUyAmxfE8ZXrgbN+zQ==",
            Base64.DEFAULT,
        )
        assertArrayEquals(hex("00112233445566778899aabbccddeeff"), RaopCrypto.unwrapAesKey(wrapped))
    }

    @Test
    fun decryptsWholeBlocksAndLeavesTheTail() {
        val plain = ByteArray(48) { (it * 7 + 3).toByte() }
        val cipherText = hex(
            "eeae64b41cc003fb6582866e7b0a0d9aee5de7ed356ff8decd6475b81d2179bc" +
                "466037b70c3428bdf9483753607e8507",
        )
        val tail = byteArrayOf(9, 8, 7)
        val packet = byteArrayOf(1, 2) + cipherText + tail
        val cipher = RaopCrypto.PacketCipher(
            hex("00112233445566778899aabbccddeeff"),
            hex("0f0e0d0c0b0a09080706050403020100"),
        )
        cipher.decrypt(packet, 2, cipherText.size + tail.size)
        assertArrayEquals(byteArrayOf(1, 2) + plain + tail, packet)
        // The IV restarts with every packet.
        val again = cipherText.copyOf()
        cipher.decrypt(again, 0, again.size)
        assertArrayEquals(plain, again)
    }

    private fun hex(s: String) = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
}
