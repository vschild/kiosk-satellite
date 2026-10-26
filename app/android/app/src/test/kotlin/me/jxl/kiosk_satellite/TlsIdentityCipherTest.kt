package me.jxl.kiosk_satellite

import org.junit.Assert.*
import org.junit.Test
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

class TlsIdentityCipherTest {
    private fun key(): SecretKey = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()

    @Test fun sealedIdentityOpensWithItsKey() {
        val key = key()
        val opened = TlsIdentityCipher.open(TlsIdentityCipher.seal("{\"imported\":true}", key), key)
        assertEquals(TlsIdentityCipher.Opened.Json("{\"imported\":true}"), opened)
    }

    @Test fun identityFromAnotherKeyIsUnreadable() {
        val opened = TlsIdentityCipher.open(TlsIdentityCipher.seal("{}", key()), key())
        assertTrue(opened is TlsIdentityCipher.Opened.Unreadable)
    }

    @Test fun missingKeyIsUnreadable() {
        val opened = TlsIdentityCipher.open(TlsIdentityCipher.seal("{}", key()), null)
        assertEquals(TlsIdentityCipher.Opened.Unreadable("its Keystore key is missing"), opened)
    }

    @Test fun truncatedFileIsUnreadable() {
        val key = key()
        val opened = TlsIdentityCipher.open(TlsIdentityCipher.seal("{}", key).copyOf(20), key)
        assertEquals(TlsIdentityCipher.Opened.Unreadable("the file is damaged"), opened)
    }

    @Test fun tamperedFileIsUnreadable() {
        val key = key()
        val bytes = TlsIdentityCipher.seal("{\"certificate\":\"x\"}", key)
        bytes[bytes.size - 1] = (bytes[bytes.size - 1].toInt() xor 1).toByte()
        assertTrue(TlsIdentityCipher.open(bytes, key) is TlsIdentityCipher.Opened.Unreadable)
    }
}
