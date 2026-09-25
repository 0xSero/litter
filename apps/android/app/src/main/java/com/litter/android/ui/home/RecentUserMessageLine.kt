package com.litter.android.ui.home

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.common.FormattedText
import com.litter.android.ui.scaled
import uniffi.codex_mobile_client.AppSessionSummary

/**
 * Single-line quote of the last user message — shown at zoom 3+ when the
 * message is both non-empty and distinct from the session title (the title
 * is often derived from the first user message, and duplicating it here
 * would be visual noise).
 *
 * Ref: HomeDashboardView.swift:859-876 (`userMessageLine`).
 */
@Composable
fun RecentUserMessageLine(
    session: AppSessionSummary,
    modifier: Modifier = Modifier,
) {
    val message = session.lastUserMessage?.trim().orEmpty()
    if (message.isEmpty()) return
    val title = session.title.trim()
    if (message == title) return

    Row(
        modifier = modifier.padding(top = 3.dp),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        FormattedText(
            text = message,
            color = LitterTheme.textSecondary,
            fontSize = LitterTextStyle.body.scaled,
            maxLines = 1,
        )
    }
}
