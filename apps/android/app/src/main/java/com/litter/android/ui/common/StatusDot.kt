package com.litter.android.ui.common

/**
 * Shared visual language for "this thing's current state" — used for task
 * rows (active / hydrating / hydrated / idle) and server pills (connected /
 * connecting / failed / idle). Colors are fixed green/orange/red so the
 * meaning reads the same across themes.
 */
enum class StatusDotState {
    /** Solid green. Something is done / healthy. */
    OK,
    /** Pulsing green. Something is live and running right now. */
    ACTIVE,
    /** Pulsing orange. Work in flight (connecting, reconnecting, loading). */
    PENDING,
    /** Solid red. Failed state that needs attention. */
    ERROR,
    /** Empty grey ring. Known-but-dormant state. */
    IDLE,
}
