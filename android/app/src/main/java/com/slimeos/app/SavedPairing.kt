package com.slimeos.app

import android.content.Context

/**
 * Keeps the pairing (the WireGuard config, which holds this device's private
 * key) and the Brain's connect details across app restarts and updates, so a
 * device pairs once — every pairing code mints a new hub peer (#44). Stored
 * encrypted, see [SealedPrefs].
 */
class SavedPairing(context: Context) {

    data class Brain(
        val host: String,
        val port: Int,
        val username: String,
        val password: String,
        val name: String = DEFAULT_BRAIN_NAME
    )

    private val store = SealedPrefs(context, "pairing")

    var wgConfig: String?
        get() = store.read(KEY_WG_CONFIG)
        set(value) = store.write(KEY_WG_CONFIG, value)

    var brain: Brain?
        get() {
            val host = store.read(KEY_HOST) ?: return null
            return Brain(
                host = host,
                port = store.read(KEY_PORT)?.toIntOrNull() ?: 3389,
                username = store.read(KEY_USERNAME) ?: "",
                password = store.read(KEY_PASSWORD) ?: "",
                // Saved before Brains had names.
                name = store.read(KEY_NAME)?.takeIf { it.isNotBlank() } ?: DEFAULT_BRAIN_NAME
            )
        }
        set(value) {
            store.write(KEY_HOST, value?.host)
            store.write(KEY_PORT, value?.port?.toString())
            store.write(KEY_USERNAME, value?.username)
            store.write(KEY_PASSWORD, value?.password)
            store.write(KEY_NAME, value?.name)
        }

    fun clear() {
        store.clear()
    }

    companion object {
        const val DEFAULT_BRAIN_NAME = "My Brain"

        private const val KEY_WG_CONFIG = "wg_config"
        private const val KEY_HOST = "brain_host"
        private const val KEY_PORT = "brain_port"
        private const val KEY_USERNAME = "brain_username"
        private const val KEY_PASSWORD = "brain_password"
        private const val KEY_NAME = "brain_name"
    }
}
