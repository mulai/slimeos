package com.slimeos.app

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Keeps the pairing (the WireGuard config, which holds this device's private
 * key) and the Brain's connect details across app restarts and updates, so a
 * device pairs once — every pairing code mints a new hub peer (#44).
 *
 * Values sit in app-private SharedPreferences, each encrypted with an AES-GCM
 * key that never leaves the Android Keystore. allowBackup is off, and a value
 * that no longer decrypts (key gone) reads as "not saved" rather than failing.
 */
class SavedPairing(context: Context) {

    data class Brain(val host: String, val port: Int, val username: String, val password: String)

    private val prefs = context.getSharedPreferences("pairing", Context.MODE_PRIVATE)

    var wgConfig: String?
        get() = read(KEY_WG_CONFIG)
        set(value) = write(KEY_WG_CONFIG, value)

    var brain: Brain?
        get() {
            val host = read(KEY_HOST) ?: return null
            return Brain(
                host = host,
                port = read(KEY_PORT)?.toIntOrNull() ?: 3389,
                username = read(KEY_USERNAME) ?: "",
                password = read(KEY_PASSWORD) ?: ""
            )
        }
        set(value) {
            write(KEY_HOST, value?.host)
            write(KEY_PORT, value?.port?.toString())
            write(KEY_USERNAME, value?.username)
            write(KEY_PASSWORD, value?.password)
        }

    fun clear() {
        prefs.edit().clear().apply()
    }

    private fun read(key: String): String? {
        val stored = prefs.getString(key, null) ?: return null
        return try {
            val bytes = Base64.decode(stored, Base64.NO_WRAP)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes, 0, IV_BYTES))
            String(cipher.doFinal(bytes, IV_BYTES, bytes.size - IV_BYTES), StandardCharsets.UTF_8)
        } catch (e: Exception) {
            null
        }
    }

    private fun write(key: String, value: String?) {
        if (value == null) {
            prefs.edit().remove(key).apply()
            return
        }
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val sealed = cipher.iv + cipher.doFinal(value.toByteArray(StandardCharsets.UTF_8))
        prefs.edit().putString(key, Base64.encodeToString(sealed, Base64.NO_WRAP)).apply()
    }

    private fun key(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return generator.generateKey()
    }

    private companion object {
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val KEY_ALIAS = "slimeos-pairing"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_BYTES = 12
        const val KEY_WG_CONFIG = "wg_config"
        const val KEY_HOST = "brain_host"
        const val KEY_PORT = "brain_port"
        const val KEY_USERNAME = "brain_username"
        const val KEY_PASSWORD = "brain_password"
    }
}
