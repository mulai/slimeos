package com.slimeos.app

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/**
 * Keeps the pairing (the WireGuard config, which holds this device's private
 * key), the saved Brains and the Slime ID session across app restarts and
 * updates, so a device pairs once — every pairing code mints a new hub peer
 * (#44). Stored encrypted, see [SealedPrefs].
 */
class SavedPairing(context: Context) {

    /**
     * A Brain saved on this tablet, as the Membrane's brains.json. [slimeIdBrainId] is
     * its id on the Slime ID account, when it came from (or matches) the account's
     * list: a paid Brain's Windows sign-in is fetched by that id.
     */
    data class Brain(
        val host: String,
        val port: Int,
        val username: String,
        val password: String,
        val name: String = DEFAULT_BRAIN_NAME,
        val id: String = UUID.randomUUID().toString(),
        val kind: String = "free",
        val slimeIdBrainId: String? = null,
        val lastConnected: Long = 0L
    ) {
        fun sameAddress(host: String, port: Int) = this.host.equals(host, ignoreCase = true) && this.port == port
    }

    private val store = SealedPrefs(context, "pairing")
    private val slimeIdStore = SealedPrefs(context, "slimeid")

    var wgConfig: String?
        get() = store.read(KEY_WG_CONFIG)
        set(value) = store.write(KEY_WG_CONFIG, value)

    var brains: List<Brain>
        get() {
            val text = store.read(KEY_BRAINS) ?: return legacyBrain()?.let { listOf(it) } ?: emptyList()
            return try {
                val array = JSONArray(text)
                (0 until array.length()).map { i -> fromJson(array.getJSONObject(i)) }
            } catch (e: Exception) {
                emptyList()
            }
        }
        set(value) {
            store.write(KEY_BRAINS, JSONArray(value.map { toJson(it) }).toString())
            LEGACY_KEYS.forEach { store.write(it, null) }
        }

    /** Adds the Brain, or replaces the saved one with the same id. */
    fun put(brain: Brain) {
        val list = brains
        brains = if (list.any { it.id == brain.id }) list.map { if (it.id == brain.id) brain else it } else list + brain
    }

    fun remove(id: String) {
        brains = brains.filterNot { it.id == id }
    }

    var slimeIdSession: SlimeId.Session?
        get() {
            val token = slimeIdStore.read(KEY_TOKEN) ?: return null
            return SlimeId.Session(token, slimeIdStore.read(KEY_EMAIL) ?: "", slimeIdStore.read(KEY_ACCOUNT_NAME) ?: "")
        }
        set(value) {
            if (value == null) {
                slimeIdStore.clear()
                return
            }
            slimeIdStore.write(KEY_TOKEN, value.token)
            slimeIdStore.write(KEY_EMAIL, value.email)
            slimeIdStore.write(KEY_ACCOUNT_NAME, value.name)
        }

    /** Forgets the pairing and the Brains; the Slime ID session stays (see [slimeIdSession]). */
    fun clear() {
        store.clear()
    }

    /** Before the Brain list: one Brain in its own keys. Moved into the list on the next write. */
    private fun legacyBrain(): Brain? {
        val host = store.read(KEY_HOST) ?: return null
        return Brain(
            host = host,
            port = store.read(KEY_PORT)?.toIntOrNull() ?: 3389,
            username = store.read(KEY_USERNAME) ?: "",
            password = store.read(KEY_PASSWORD) ?: "",
            // Saved before Brains had names.
            name = store.read(KEY_NAME)?.takeIf { it.isNotBlank() } ?: DEFAULT_BRAIN_NAME,
            // Stable until it's moved into the list.
            id = "legacy"
        )
    }

    private fun toJson(b: Brain) = JSONObject()
        .put("id", b.id).put("name", b.name).put("host", b.host).put("port", b.port)
        .put("username", b.username).put("password", b.password).put("kind", b.kind)
        .put("slimeIdBrainId", b.slimeIdBrainId ?: JSONObject.NULL).put("lastConnected", b.lastConnected)

    private fun fromJson(o: JSONObject) = Brain(
        host = o.getString("host"),
        port = o.optInt("port", 3389),
        username = o.optString("username"),
        password = o.optString("password"),
        name = o.optString("name").ifBlank { DEFAULT_BRAIN_NAME },
        id = o.getString("id"),
        kind = o.optString("kind", "free"),
        slimeIdBrainId = if (o.isNull("slimeIdBrainId")) null else o.optString("slimeIdBrainId").ifEmpty { null },
        lastConnected = o.optLong("lastConnected", 0L)
    )

    companion object {
        const val DEFAULT_BRAIN_NAME = "My Brain"

        private const val KEY_WG_CONFIG = "wg_config"
        private const val KEY_BRAINS = "brains"
        private const val KEY_HOST = "brain_host"
        private const val KEY_PORT = "brain_port"
        private const val KEY_USERNAME = "brain_username"
        private const val KEY_PASSWORD = "brain_password"
        private const val KEY_NAME = "brain_name"
        private val LEGACY_KEYS = listOf(KEY_HOST, KEY_PORT, KEY_USERNAME, KEY_PASSWORD, KEY_NAME)

        private const val KEY_TOKEN = "token"
        private const val KEY_EMAIL = "email"
        private const val KEY_ACCOUNT_NAME = "name"
    }
}
