package com.litter.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/**
 * Launch splash: theme background with the static Litter mark centered.
 * No per-frame animation; MainActivity fades the whole layer out once the
 * first real frame is composed.
 */
@Composable
fun AnimatedSplashScreen() {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(LitterTheme.background),
        contentAlignment = Alignment.Center,
    ) {
        LitterMark(size = 96.dp, color = LitterTheme.textSecondary)
    }
}
