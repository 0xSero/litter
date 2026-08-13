package com.litter.android.ui.conversation

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.CloseFullscreen
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.scaled

/**
 * Full-screen composer for writing long prompts. Opened from the inline
 * composer's expand icon; shares the same `text` state so edits round-trip
 * back when the dialog is dismissed. Matches `ConversationComposerExpandedView`
 * on iOS.
 */
@Composable
fun ComposerExpandedDialog(
    text: String,
    onTextChange: (String) -> Unit,
    onSend: () -> Unit,
    onDismiss: () -> Unit,
    canSend: Boolean,
    placeholder: String = "Message\u2026",
) {
    val focusRequester = remember { FocusRequester() }
    LaunchedEffect(Unit) { focusRequester.requestFocus() }

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(
            usePlatformDefaultWidth = false,
            dismissOnBackPress = true,
            dismissOnClickOutside = false,
        ),
    ) {
        Surface(
            modifier = Modifier.fillMaxSize(),
            color = LitterTheme.background,
        ) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .imePadding(),
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    IconButton(
                        onClick = onDismiss,
                        modifier = Modifier.size(40.dp),
                    ) {
                        Icon(
                            imageVector = Icons.Default.CloseFullscreen,
                            contentDescription = "Collapse composer",
                            tint = LitterTheme.textPrimary,
                        )
                    }
                    Spacer(Modifier.weight(1f))
                    if (canSend) {
                        IconButton(
                            onClick = {
                                onSend()
                                onDismiss()
                            },
                            modifier = Modifier
                                .size(40.dp)
                                .clip(CircleShape)
                                .background(LitterTheme.accent, CircleShape),
                        ) {
                            Icon(
                                imageVector = Icons.AutoMirrored.Filled.Send,
                                contentDescription = "Send",
                                tint = Color.Black,
                                modifier = Modifier.size(20.dp),
                            )
                        }
                    }
                }

                Box(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                ) {
                    if (text.isEmpty()) {
                        Text(
                            text = placeholder,
                            color = LitterTheme.textMuted,
                            fontSize = LitterTextStyle.body.scaled,
                        )
                    }
                    BasicTextField(
                        value = text,
                        onValueChange = onTextChange,
                        textStyle = TextStyle(
                            color = LitterTheme.textPrimary,
                            fontSize = LitterTextStyle.body.scaled,
                            fontFamily = LitterTheme.bodyFont,
                        ),
                        cursorBrush = SolidColor(LitterTheme.accent),
                        modifier = Modifier
                            .fillMaxSize()
                            .focusRequester(focusRequester),
                    )
                }
            }
        }
    }
}
