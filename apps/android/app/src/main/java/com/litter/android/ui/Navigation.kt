package com.litter.android.ui

import uniffi.codex_mobile_client.ThreadKey

/**
 * Type-safe navigation routes for the app.
 */
sealed class Route {
    data object Home : Route()
    data class Conversation(val key: ThreadKey) : Route()
    data class RealtimeVoice(val key: ThreadKey) : Route()
    data class ConversationInfo(val key: ThreadKey) : Route()
    data class WallpaperSelection(val key: ThreadKey) : Route()
    data class WallpaperAdjust(val key: ThreadKey) : Route()
    data class ServerInfo(val serverId: String) : Route()
    data class ServerWallpaperSelection(val serverId: String) : Route()
    data class ServerWallpaperAdjust(val serverId: String) : Route()
    data object Apps : Route()
    data class SavedApp(val appId: String) : Route()
    data class Terminal(val preferredAlleycatNodeId: String? = null) : Route()
}
