package com.slimeos.app

import android.content.Context
import android.util.Base64
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.PBEKeySpec

/**
 * The app's PIN: chosen by the user on first run, asked when the app opens and
 * after a while in the background. It guards the saved Brain password and the
 * pairing on a tablet someone else picks up.
 *
 * Unlike the Membrane's recovery PIN (shown once at install), the user picks it,
 * so there is nothing to write down. A forgotten PIN means resetting the app
 * (wipes the pairing and the Brain details; a new pairing code is needed), never
 * a way around it. Uninstalling does the same: the files and the Keystore key go.
 *
 * Only a salted PBKDF2 hash is kept, inside [SealedPrefs]. Wrong PINs lock entry
 * for longer and longer, like the Membrane's PIN lockout (pinRetryAt).
 */
class AppLock(context: Context) {

    sealed class Check {
        object Ok : Check()
        /** Wrong; [triesBeforeWait] more before entry locks for a while. */
        data class Wrong(val triesBeforeWait: Int) : Check()
        data class Wait(val untilMs: Long) : Check()
    }

    private val store = SealedPrefs(context, "applock")

    val isSet: Boolean get() = store.read(KEY_HASH) != null

    /** Wall-clock ms until which entry is locked, 0 when it isn't. */
    val retryAtMs: Long
        get() {
            val at = store.read(KEY_RETRY_AT)?.toLongOrNull() ?: return 0
            val now = System.currentTimeMillis()
            // A clock set back must not lengthen the wait past the longest step.
            return if (at <= now) 0 else minOf(at, now + LOCKOUT_MS.last())
        }

    /** Slow on purpose (PBKDF2): call off the main thread. */
    fun set(pin: String) {
        val salt = ByteArray(16).also { SecureRandom().nextBytes(it) }
        store.write(KEY_SALT, Base64.encodeToString(salt, Base64.NO_WRAP))
        store.write(KEY_HASH, Base64.encodeToString(hash(pin, salt), Base64.NO_WRAP))
        store.write(KEY_FAILURES, null)
        store.write(KEY_RETRY_AT, null)
    }

    /** Slow on purpose (PBKDF2): call off the main thread. */
    fun check(pin: String): Check {
        val wait = retryAtMs
        if (wait != 0L) return Check.Wait(wait)
        val salt = store.read(KEY_SALT)?.let { Base64.decode(it, Base64.NO_WRAP) }
        val expected = store.read(KEY_HASH)?.let { Base64.decode(it, Base64.NO_WRAP) }
        if (salt == null || expected == null) return Check.Ok // no PIN set
        if (MessageDigest.isEqual(hash(pin, salt), expected)) {
            store.write(KEY_FAILURES, null)
            store.write(KEY_RETRY_AT, null)
            return Check.Ok
        }
        val failures = (store.read(KEY_FAILURES)?.toIntOrNull() ?: 0) + 1
        store.write(KEY_FAILURES, failures.toString())
        if (failures < FREE_TRIES) return Check.Wrong(FREE_TRIES - failures)
        val step = LOCKOUT_MS[minOf(failures - FREE_TRIES, LOCKOUT_MS.size - 1)]
        val until = System.currentTimeMillis() + step
        store.write(KEY_RETRY_AT, until.toString())
        return Check.Wait(until)
    }

    fun clear() {
        store.clear()
    }

    private fun hash(pin: String, salt: ByteArray): ByteArray {
        val spec = PBEKeySpec(pin.toCharArray(), salt, ITERATIONS, 256)
        return try {
            SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded
        } finally {
            spec.clearPassword()
        }
    }

    companion object {
        const val PIN_LENGTH = 6

        private const val KEY_HASH = "pin_hash"
        private const val KEY_SALT = "pin_salt"
        private const val KEY_FAILURES = "pin_failures"
        private const val KEY_RETRY_AT = "pin_retry_at"
        // Unnoticeable once, slow for guessing the hash off the device.
        private const val ITERATIONS = 60_000
        private const val FREE_TRIES = 5
        // After FREE_TRIES wrong PINs: 30 s, 1 min, 5 min, then 15 min a try.
        private val LOCKOUT_MS = longArrayOf(30_000, 60_000, 5 * 60_000, 15 * 60_000)
    }
}
