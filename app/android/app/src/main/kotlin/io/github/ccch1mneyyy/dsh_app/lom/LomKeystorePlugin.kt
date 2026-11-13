package io.github.ccch1mneyyy.dsh_app.lom

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Keystore protection for the Lom identity private keys (doc §04).
 *
 * The AES-256-GCM wrapping key lives in the Android Keystore under alias
 * [KEY_ALIAS] (never exportable); the wrapped private bytes live in
 * `noBackupFilesDir/lom_identity.bin`, so they never enter a system backup.
 * Plaintext private keys only cross the channel as in-memory arguments —
 * never in storage, logs, or crash reports.
 *
 * MethodChannel `dsh/lom_keystore` (all payloads are unpadded base64url):
 * - `wrap`: {plaintext} -> {wrapped}          (IV 12B ‖ ciphertext ‖ tag 16B)
 * - `unwrap`: {wrapped} -> {plaintext}
 * - `loadWrapped`: {} -> {wrapped} | null
 * - `saveWrapped`: {wrapped} -> {}
 * - `deleteWrapped`: {} -> {}
 */
class LomKeystorePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var context: Context
    private lateinit var methods: MethodChannel

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "wrap" -> {
                    val plaintext = decodeArg(call, "plaintext") ?: return result.error("bad_arg", null, null)
                    result.success(encode(wrap(plaintext)))
                }
                "unwrap" -> {
                    val wrapped = decodeArg(call, "wrapped") ?: return result.error("bad_arg", null, null)
                    val plain = unwrap(wrapped) ?: return result.error("unwrap_failed", null, null)
                    result.success(encode(plain))
                }
                "loadWrapped" -> {
                    val file = identityFile()
                    result.success(if (file.exists()) encode(file.readBytes()) else null)
                }
                "saveWrapped" -> {
                    val wrapped = decodeArg(call, "wrapped") ?: return result.error("bad_arg", null, null)
                    identityFile().writeBytes(wrapped)
                    result.success(null)
                }
                "deleteWrapped" -> {
                    identityFile().delete()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (_: Exception) {
            // Never leak key material or file paths in the error.
            result.error("lom_keystore_error", null, null)
        }
    }

    private fun identityFile(): File = File(context.noBackupFilesDir, FILE_NAME)

    private fun wrappingKey(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }

    /** AES-256-GCM, fresh random 12-byte IV per wrap: IV ‖ ciphertext ‖ tag. */
    private fun wrap(plaintext: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, wrappingKey())
        val sealed = cipher.doFinal(plaintext)
        return cipher.iv + sealed
    }

    private fun unwrap(wrapped: ByteArray): ByteArray? {
        if (wrapped.size < IV_BYTES + TAG_BYTES) return null
        val iv = wrapped.copyOfRange(0, IV_BYTES)
        val sealed = wrapped.copyOfRange(IV_BYTES, wrapped.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, wrappingKey(), GCMParameterSpec(TAG_BITS, iv))
        return try {
            cipher.doFinal(sealed)
        } catch (_: Exception) {
            null
        }
    }

    private fun decodeArg(call: MethodCall, name: String): ByteArray? {
        val value = call.argument<String>(name) ?: return null
        return decode(value)
    }

    companion object {
        const val CHANNEL = "dsh/lom_keystore"
        private const val KEY_ALIAS = "lom_identity_wrap"
        private const val FILE_NAME = "lom_identity.bin"
        private const val IV_BYTES = 12
        private const val TAG_BITS = 128
        private const val TAG_BYTES = 16

        fun encode(bytes: ByteArray): String =
            Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)

        fun decode(s: String): ByteArray? = try {
            Base64.decode(s, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
        } catch (_: IllegalArgumentException) {
            null
        }
    }
}
