package local.adbremote.android.ui

import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.InsertDriveFile
import androidx.compose.material.icons.filled.CreateNewFolder
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Upload
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import local.adbremote.android.bridge.AdbException
import local.adbremote.android.bridge.RemoteFile
import local.adbremote.android.model.DeviceStore
import local.adbremote.android.model.FilesModel
import local.adbremote.android.model.formatBytes
import java.io.File
import java.text.DateFormat
import java.util.Date

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun FilesScreen(store: DeviceStore, modifier: Modifier) {
    val context = LocalContext.current
    val session = store.selectedSession
    val model = session?.takeIf { it.isConnected }?.filesModel()
    var path by rememberSaveable { mutableStateOf(FilesModel.HOME) }
    var entries by remember { mutableStateOf<List<RemoteFile>?>(null) }
    var listError by remember { mutableStateOf<String?>(null) }
    var reload by remember { mutableIntStateOf(0) }
    var menuFor by remember { mutableStateOf<RemoteFile?>(null) }
    var renaming by remember { mutableStateOf<RemoteFile?>(null) }
    var deleting by remember { mutableStateOf<RemoteFile?>(null) }
    var newFolder by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf<File?>(null) }

    val upload = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        if (uris.isEmpty() || model == null) return@rememberLauncherForActivityResult
        val folder = path
        store.scope.launch {
            val dir = store.cacheDir("upload")
            val files = uris.map { uri ->
                val name = displayName(context, uri) ?: "file"
                name to copyToCache(context, uri, dir, name)
            }
            model.upload(files, folder)
            reload++
        }
    }
    val save = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("*/*")) { uri ->
        val file = saving ?: return@rememberLauncherForActivityResult
        saving = null
        if (uri != null) store.scope.launch { copyToUri(context, file, uri) }
    }

    Column(modifier.fillMaxSize()) {
        DeviceBar(store, "Files") {
            if (model != null) {
                IconButton(onClick = { newFolder = true }, Modifier.semantics { contentDescription = "New folder" }) {
                    Icon(Icons.Default.CreateNewFolder, null)
                }
                IconButton(onClick = { upload.launch(arrayOf("*/*")) }, Modifier.semantics { contentDescription = "Upload" }) {
                    Icon(Icons.Default.Upload, null)
                }
            }
        }
        if (model == null) {
            NotConnected(store)
            return@Column
        }
        LaunchedEffect(model, path, reload) {
            listError = null
            try {
                entries = model.list(path)
            } catch (e: AdbException) {
                entries = emptyList()
                listError = e.message
            }
        }
        val parent = path.substringBeforeLast('/', "").ifEmpty { "/" }
        BackHandler(enabled = path != "/") { path = parent }

        Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 8.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            for (location in model.locations) {
                AssistChip(onClick = { path = location.path }, label = { Text(location.name) })
            }
        }
        Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
            if (path != "/") IconButton(onClick = { path = parent }, Modifier.semantics { contentDescription = "Up" }) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, null)
            }
            Column {
                Text(model.title(path), style = MaterialTheme.typography.titleMedium)
                Text(path, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        if (entries == null) LinearProgressIndicator(Modifier.fillMaxWidth())
        Box(Modifier.fillMaxSize()) {
            LazyColumn(Modifier.fillMaxSize(), contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 88.dp)) {
                items(entries ?: emptyList(), key = { it.name }) { entry ->
                    Box {
                        ListItem(
                            headlineContent = { Text(entry.name) },
                            supportingContent = {
                                val date = DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(entry.modified))
                                Text(if (entry.isDirectory) date else "${formatBytes(entry.size)} · $date")
                            },
                            leadingContent = {
                                Icon(if (entry.isDirectory) Icons.Default.Folder else Icons.AutoMirrored.Filled.InsertDriveFile, null)
                            },
                            modifier = Modifier.combinedClickable(
                                onClick = { if (entry.isDirectory) path = FilesModel.join(path, entry.name) else menuFor = entry },
                                onLongClick = { menuFor = entry },
                            ),
                        )
                        DropdownMenu(expanded = menuFor == entry, onDismissRequest = { menuFor = null }) {
                            if (!entry.isDirectory) {
                                DropdownMenuItem(text = { Text("Save to Phone") }, onClick = {
                                    menuFor = null
                                    val folder = path
                                    store.scope.launch {
                                        val file = model.download(entry, folder) ?: return@launch
                                        saving = file
                                        save.launch(entry.name)
                                    }
                                })
                                DropdownMenuItem(text = { Text("Open on Device") }, onClick = {
                                    menuFor = null
                                    val folder = path
                                    store.scope.launch { model.openOnDevice(entry, folder) }
                                })
                            }
                            DropdownMenuItem(text = { Text("Rename") }, onClick = {
                                menuFor = null
                                renaming = entry
                            })
                            DropdownMenuItem(text = { Text("Delete", color = MaterialTheme.colorScheme.error) }, onClick = {
                                menuFor = null
                                deleting = entry
                            })
                        }
                    }
                }
            }
            StatusBanner(model.activity, model.error ?: listError, model.message, Modifier.align(Alignment.BottomCenter)) {
                model.error = null
                model.message = null
                listError = null
            }
        }

        if (newFolder) NameDialog("New Folder", "", "Create", onDismiss = { newFolder = false }) { name ->
            newFolder = false
            val folder = path
            store.scope.launch {
                model.createFolder(name, folder)
                reload++
            }
        }
        renaming?.let { entry ->
            NameDialog("Rename", entry.name, "Rename", onDismiss = { renaming = null }) { name ->
                renaming = null
                val folder = path
                store.scope.launch {
                    model.rename(entry, folder, name)
                    reload++
                }
            }
        }
        deleting?.let { entry ->
            AlertDialog(
                onDismissRequest = { deleting = null },
                title = { Text("Delete ${entry.name}?") },
                text = { if (entry.isDirectory) Text("Everything inside this folder is deleted too.") },
                confirmButton = {
                    TextButton(onClick = {
                        deleting = null
                        val folder = path
                        store.scope.launch {
                            model.delete(entry, folder)
                            reload++
                        }
                    }) { Text("Delete", color = MaterialTheme.colorScheme.error) }
                },
                dismissButton = { TextButton(onClick = { deleting = null }) { Text("Cancel") } },
            )
        }
    }
}

@Composable
private fun NameDialog(title: String, initial: String, action: String, onDismiss: () -> Unit, onDone: (String) -> Unit) {
    var name by remember { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { OutlinedTextField(name, { name = it }, singleLine = true) },
        confirmButton = { TextButton(enabled = name.isNotBlank() && !name.contains('/'), onClick = { onDone(name.trim()) }) { Text(action) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
