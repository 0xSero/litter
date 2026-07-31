package com.litter.android.state

import android.content.Context
import android.util.Base64

class AlleycatCredentialStore(context: Context) {
    private val prefs = openEncryptedPrefsOrReset(context, PREFS_NAME)

    fun loadToken(nodeId: String): String? =
        prefs.getString(key(nodeId), null)?.takeIf { it.isNotBlank() }

    fun saveToken(nodeId: String, token: String) {
        check(prefs.edit().putString(key(nodeId), token).commit()) { "Unable to save Alleycat token" }
    }

    fun deleteToken(nodeId: String) {
        prefs.edit().remove(key(nodeId)).apply()
    }

    /**
     * Load the persisted iroh device secret key (32 bytes, base64-encoded
     * in encrypted prefs) or null if not yet generated.
     */
    fun loadDeviceSecretKey(): ByteArray? {
        val encoded = prefs.getString(DEVICE_KEY, null)?.takeIf { it.isNotBlank() } ?: return null
        return runCatching { Base64.decode(encoded, Base64.NO_WRAP) }
            .getOrNull()
            ?.takeIf { it.size == 32 }
    }

    /** Persist the iroh device secret key bytes. */
    fun saveDeviceSecretKey(bytes: ByteArray) {
        require(bytes.size == 32) { "iroh secret key must be 32 bytes" }
        val encoded = Base64.encodeToString(bytes, Base64.NO_WRAP)
        prefs.edit().putString(DEVICE_KEY, encoded).apply()
    }

    private fun key(nodeId: String): String =
        nodeId.trim().lowercase()

    companion object {
        private const val PREFS_NAME = "alleycat_credentials"
        private const val DEVICE_KEY = "__device_secret_key__"
    }
}
