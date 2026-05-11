package com.litter.android.state

import android.content.Context
import android.system.Os

class OpenAIApiKeyStore(context: Context) {
    private val prefs = openEncryptedPrefsOrReset(context, PREFS_NAME)

    fun hasStoredKey(): Boolean = !load().isNullOrBlank()
    fun hasStoredBaseUrl(): Boolean = !loadBaseUrl().isNullOrBlank()

    fun load(): String? {
        val raw = prefs.getString(KEY_API_KEY, null)?.trim()
        return raw?.takeIf { it.isNotEmpty() }
    }

    fun loadBaseUrl(): String? {
        val raw = prefs.getString(KEY_BASE_URL, null)?.trim()
        return raw?.takeIf { it.isNotEmpty() }
    }

    fun save(apiKey: String) {
        val trimmed = apiKey.trim()
        prefs.edit().putString(KEY_API_KEY, trimmed).commit()
        applyToEnvironment()
    }

    fun saveBaseUrl(baseUrl: String) {
        val trimmed = baseUrl.trim()
        prefs.edit().putString(KEY_BASE_URL, trimmed).commit()
        applyToEnvironment()
    }

    fun clear() {
        prefs.edit().remove(KEY_API_KEY).commit()
        try {
            Os.unsetenv(API_KEY_ENV_KEY)
        } catch (_: Exception) {
        }
    }

    fun clearBaseUrl() {
        prefs.edit().remove(KEY_BASE_URL).commit()
        try {
            Os.unsetenv(BASE_URL_ENV_KEY)
        } catch (_: Exception) {
        }
    }

    fun applyToEnvironment() {
        val key = load()
        val baseUrl = loadBaseUrl()
        try {
            if (key.isNullOrEmpty()) {
                Os.unsetenv(API_KEY_ENV_KEY)
            } else {
                Os.setenv(API_KEY_ENV_KEY, key, true)
            }

            if (baseUrl.isNullOrEmpty()) {
                Os.unsetenv(BASE_URL_ENV_KEY)
            } else {
                Os.setenv(BASE_URL_ENV_KEY, baseUrl, true)
            }
        } catch (_: Exception) {
        }
    }

    companion object {
        private const val PREFS_NAME = "litter_openai_api_key"
        private const val KEY_API_KEY = "openai_api_key"
        private const val KEY_BASE_URL = "openai_base_url"
        private const val API_KEY_ENV_KEY = "OPENAI_API_KEY"
        private const val BASE_URL_ENV_KEY = "OPENAI_BASE_URL"
    }
}
