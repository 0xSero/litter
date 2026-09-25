package com.litter.android.ui.home

import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.scaled
import uniffi.codex_mobile_client.AppProject
import uniffi.codex_mobile_client.projectDefaultLabel

@Composable
fun ProjectPickerSheet(
    projects: List<AppProject>,
    serverNamesById: Map<String, String>,
    isLocalById: Map<String, Boolean>,
    onSelect: (AppProject) -> Unit,
    onCreateNew: () -> Unit,
    onDismiss: () -> Unit,
) {
    var query by remember { mutableStateOf("") }
    val filtered = remember(query, projects) {
        val trimmed = query.trim().lowercase()
        if (trimmed.isEmpty()) projects
        else projects.filter { project ->
            val label = projectDefaultLabel(project.cwd).lowercase()
            val server = (serverNamesById[project.serverId] ?: "").lowercase()
            label.contains(trimmed) ||
                project.cwd.lowercase().contains(trimmed) ||
                server.contains(trimmed)
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(LitterTheme.background),
    ) {
        // Header
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 8.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TextButton(onClick = onDismiss) {
                Text("Close", color = LitterTheme.textSecondary)
            }
            Spacer(Modifier.weight(1f))
            Text(
                text = "Projects",
                color = LitterTheme.textPrimary,
                fontSize = LitterTextStyle.body.scaled,
                fontWeight = FontWeight.SemiBold,
            )
            Spacer(Modifier.weight(1f))
            IconButton(onClick = onCreateNew) {
                Icon(
                    imageVector = Icons.Default.Add,
                    contentDescription = "New project",
                    tint = LitterTheme.textPrimary,
                )
            }
        }

        // Search
        OutlinedTextField(
            value = query,
            onValueChange = { query = it },
            placeholder = { Text("Search projects", color = LitterTheme.textMuted) },
            leadingIcon = {
                Icon(
                    imageVector = Icons.Default.Search,
                    contentDescription = null,
                    tint = LitterTheme.textMuted,
                )
            },
            trailingIcon = {
                if (query.isNotEmpty()) {
                    IconButton(onClick = { query = "" }) {
                        Icon(
                            imageVector = Icons.Default.Close,
                            contentDescription = "Clear",
                            tint = LitterTheme.textMuted,
                        )
                    }
                }
            },
            singleLine = true,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 4.dp),
        )

        Spacer(Modifier.height(8.dp))

        if (filtered.isEmpty()) {
            Column(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .padding(horizontal = 32.dp, vertical = 60.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Icon(
                    imageVector = Icons.Default.Folder,
                    contentDescription = null,
                    tint = LitterTheme.textMuted,
                    modifier = Modifier.size(32.dp),
                )
                Text(
                    text = "No projects yet",
                    color = LitterTheme.textSecondary,
                    fontSize = LitterTextStyle.body.scaled,
                    fontWeight = FontWeight.Medium,
                )
                Text(
                    text = "Tap + to pick a directory and start your first thread.",
                    color = LitterTheme.textMuted,
                    fontSize = LitterTextStyle.footnote.scaled,
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                )
                TextButton(onClick = onCreateNew) {
                    Text("New Project", color = LitterTheme.textPrimary)
                }
            }
        } else {
            LazyColumn(modifier = Modifier.weight(1f)) {
                items(filtered, key = { it.id }) { project ->
                    ProjectRow(
                        project = project,
                        serverName = serverNamesById[project.serverId],
                        isLocal = isLocalById[project.serverId] == true,
                        onClick = {
                            onSelect(project)
                            onDismiss()
                        },
                    )
                    HorizontalDivider(color = LitterTheme.textMuted.copy(alpha = 0.08f))
                }
            }
        }
    }
}

@Composable
private fun ProjectRow(
    project: AppProject,
    serverName: String?,
    isLocal: Boolean,
    onClick: () -> Unit,
) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val path = com.litter.android.state.PathDisplay.display(project.cwd, isLocal, context)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 62.dp)
            .clickable(onClick = onClick)
            .padding(horizontal = 20.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp, Alignment.CenterVertically),
    ) {
        Text(
            text = projectDefaultLabel(project.cwd),
            color = LitterTheme.textPrimary,
            fontSize = LitterTextStyle.body.scaled,
            maxLines = 1,
            overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
        )
        Text(
            text = listOfNotNull(serverName, path).joinToString(" · ").lowercase(),
            color = LitterTheme.textSecondary,
            fontSize = LitterTextStyle.footnote.scaled,
            fontFamily = LitterTheme.monoFont,
            maxLines = 1,
            overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
        )
    }
}

