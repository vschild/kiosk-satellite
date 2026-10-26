package me.jxl.kiosk_satellite

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.AtomicFile
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.NetworkInterface
import java.security.KeyStore
import java.security.cert.X509Certificate
import java.util.Collections
import java.util.concurrent.Executors
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import org.json.JSONObject

/** Keeps the exportable server key encrypted under a device Keystore key. */
class TlsBridge(context: Context, messenger: BinaryMessenger) {
    private val file = AtomicFile(File(context.noBackupFilesDir, "tls-identity"))
    private val worker = Executors.newSingleThreadExecutor { Thread(it, "ks-tls").apply { isDaemon = true } }
    private val main = Handler(Looper.getMainLooper())

    /** Why [load] moved an unreadable identity aside, reported with the next reply. */
    private var setAside: String? = null

    init {
        MethodChannel(messenger, "kiosk_satellite/tls").setMethodCallHandler { call, result ->
            worker.execute {
                if (call.method == "userAuthorities") {
                    val reply: Map<String, Any?> = try {
                        mapOf("authorities" to userAuthorities())
                    } catch (e: Exception) {
                        mapOf("authorities" to emptyList<Any>(), "error" to (e.message ?: e.javaClass.simpleName))
                    }
                    main.post { result.success(reply) }
                    return@execute
                }
                try {
                    val old = if (call.method == "replace" || call.method == "import") null else load()
                    val material = when (call.method) {
                        "load" -> old ?: generate(call.argument<String>("hostname"), null)
                        "renew" -> {
                            require(old?.imported != true) { "Import a renewed certificate from its issuer." }
                            generate(call.argument<String>("hostname"), old)
                        }
                        "replace" -> generate(call.argument<String>("hostname"), null)
                        "import" -> TlsMaterial.parse(call.argument<String>("certificate") ?: "",
                            call.argument<String>("privateKey") ?: "", true).also { it.validate() }
                        else -> { main.post { result.notImplemented() }; return@execute }
                    }
                    if (old == null || call.method != "load") save(material)
                    val map = setAside?.let { material.toMap() + ("unreadable" to it) } ?: material.toMap()
                    setAside = null
                    main.post { result.success(map) }
                } catch (e: Exception) {
                    main.post { result.error("tls", e.message ?: e.javaClass.simpleName, null) }
                }
            }
        }
    }

    /**
     * Certificate authorities the user installed under Android's security
     * settings, as PEM with the subject and expiry for the app log. dart:io
     * reads only the system store, so without
     * these a server signed by a private CA fails every Dart connection
     * while the WebView, which follows the network security config, trusts it.
     */
    private fun userAuthorities(): List<Map<String, Any>> {
        val store = KeyStore.getInstance("AndroidCAStore").apply { load(null) }
        return Collections.list(store.aliases())
            .filter { it.startsWith("user:") }
            .mapNotNull { store.getCertificate(it) as? X509Certificate }
            .map { cert ->
                val body = Base64.encodeToString(cert.encoded, Base64.NO_WRAP)
                    .chunked(64).joinToString("\n")
                mapOf(
                    "pem" to "-----BEGIN CERTIFICATE-----\n$body\n-----END CERTIFICATE-----\n",
                    "subject" to cert.subjectX500Principal.name,
                    "notAfter" to cert.notAfter.time,
                )
            }
    }

    private fun generate(hostname: String?, old: TlsMaterial?): TlsMaterial {
        val addresses = Collections.list(NetworkInterface.getNetworkInterfaces())
            .flatMap { Collections.list(it.inetAddresses) }
            .filter { !it.isLoopbackAddress && !it.isLinkLocalAddress }
            .mapNotNull { it.hostAddress?.substringBefore('%') }
        return TlsMaterial.generate(listOf("localhost") +
            listOfNotNull(hostname?.takeIf { it.isNotBlank() }?.let { "$it.local" }),
            addresses + listOf("127.0.0.1", "::1"), old)
    }

    private fun existingKey(): SecretKey? {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        return store.getKey("ks-tls-storage", null) as? SecretKey
    }

    private fun storageKey(): SecretKey = existingKey()
        ?: KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder("ks-tls-storage", KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()

    /**
     * The stored identity, or null when there is none. Keystore keys never
     * come along when app data is restored to another device or ROM, so the
     * restored file can no longer be opened. It moves to tls-identity.unreadable
     * and the caller generates a new identity, instead of failing every call.
     */
    private fun load(): TlsMaterial? {
        if (!file.baseFile.exists() && !File(file.baseFile.path + ".bak").exists()) return null
        val opened = TlsIdentityCipher.open(file.readFully(), existingKey())
        val json = when (opened) {
            is TlsIdentityCipher.Opened.Json -> JSONObject(opened.text)
            is TlsIdentityCipher.Opened.Unreadable -> {
                val aside = File(file.baseFile.path + ".unreadable")
                aside.delete()
                check(file.baseFile.renameTo(aside)) { "Could not move the unreadable TLS identity aside." }
                setAside = opened.reason
                return null
            }
        }
        return TlsMaterial.parse(json.getString("certificate"), json.getString("privateKey"), json.optBoolean("imported"))
    }

    private fun save(material: TlsMaterial) {
        material.validate()
        val bytes = TlsIdentityCipher.seal(JSONObject(material.toMap()).toString(), storageKey())
        val stream = file.startWrite()
        try { stream.write(bytes); file.finishWrite(stream) }
        catch (e: Exception) { file.failWrite(stream); throw e }
    }
}

/** The tls-identity layout: a 12-byte IV followed by the AES-GCM ciphertext and tag. */
internal object TlsIdentityCipher {
    sealed class Opened {
        data class Json(val text: String) : Opened()
        data class Unreadable(val reason: String) : Opened()
    }

    fun seal(json: String, key: SecretKey): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key) }
        return cipher.iv + cipher.doFinal(json.toByteArray(Charsets.UTF_8))
    }

    /**
     * Opens [bytes] with [key], or says why they can never be opened: the key
     * is gone, the file is too short or the key no longer matches. Anything
     * else, such as a keystore that is not ready yet, still throws so a
     * passing fault does not cost the identity.
     */
    fun open(bytes: ByteArray, key: SecretKey?): Opened {
        if (key == null) return Opened.Unreadable("its Keystore key is missing")
        if (bytes.size <= 28) return Opened.Unreadable("the file is damaged")
        return try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
                init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
            }
            Opened.Json(String(cipher.doFinal(bytes.copyOfRange(12, bytes.size)), Charsets.UTF_8))
        } catch (e: AEADBadTagException) {
            Opened.Unreadable("it was encrypted with a different Keystore key")
        } catch (e: KeyPermanentlyInvalidatedException) {
            Opened.Unreadable("its Keystore key was invalidated")
        }
    }
}
