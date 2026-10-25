package local.adbremote.android.ui

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Android
import androidx.compose.material.icons.filled.InstallMobile
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Checkbox
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import local.adbremote.android.bridge.InstalledApp
import local.adbremote.android.model.AppsModel
import local.adbremote.android.model.DeviceStore
import java.io.File

@Composable
fun AppsScreen(store: DeviceStore, modifier: Modifier) {
    val context = LocalContext.current
    val session = store.selectedSession
    val model = session?.takeIf { it.isConnected }?.appsModel()
    val install = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri == null || model == null) return@rememberLauncherForActivityResult
        store.scope.launch {
            val name = displayName(context, uri) ?: "app.apk"
            val file = copyToCache(context, uri, store.cacheDir("install"), name)
            model.install(file, name)
        }
    }
    var searching by rememberSaveable { mutableStateOf(false) }
    var search by rememberSaveable { mutableStateOf("") }
    var showSystem by rememberSaveable { mutableStateOf(false) }
    var menu by remember { mutableStateOf(false) }
    Column(modifier.fillMaxSize()) {
        DeviceBar(store, "Apps") {
            if (model != null) {
                IconButton(onClick = { install.launch(arrayOf("*/*")) }, Modifier.semantics { contentDescription = "Install app" }) {
                    Icon(Icons.Default.InstallMobile, null)
                }
                Box {
                    IconButton(onClick = { menu = true }, Modifier.semantics { contentDescription = "More" }) {
                        Icon(Icons.Default.MoreVert, null)
                    }
                    DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                        DropdownMenuItem(
                            text = { Text(if (searching) "Hide Search" else "Search") },
                            leadingIcon = { Icon(Icons.Default.Search, null) },
                            onClick = {
                                menu = false
                                searching = !searching
                                if (!searching) search = ""
                            },
                        )
                        DropdownMenuItem(
                            text = { Text("Show System Apps") },
                            leadingIcon = { Checkbox(checked = showSystem, onCheckedChange = null) },
                            onClick = {
                                menu = false
                                showSystem = !showSystem
                            },
                        )
                        DropdownMenuItem(
                            text = { Text("Refresh") },
                            leadingIcon = { Icon(Icons.Default.Refresh, null) },
                            onClick = {
                                menu = false
                                store.scope.launch { model.refresh() }
                            },
                        )
                    }
                }
            }
        }
        if (model == null) {
            NotConnected(store)
            return@Column
        }
        if (searching) {
            OutlinedTextField(search, { search = it }, Modifier.fillMaxWidth().padding(horizontal = 12.dp),
                placeholder = { Text("Search apps") }, singleLine = true,
                leadingIcon = { Icon(Icons.Default.Search, null) },
                trailingIcon = {
                    IconButton(onClick = { searching = false; search = "" }, Modifier.semantics { contentDescription = "Close search" }) {
                        Icon(Icons.Default.Close, null)
                    }
                })
        }
        AppsContent(store, model, search, showSystem)
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun AppsContent(store: DeviceStore, model: AppsModel, search: String, showSystem: Boolean) {
    val context = LocalContext.current
    var menuFor by remember { mutableStateOf<InstalledApp?>(null) }
    var confirmUninstall by remember { mutableStateOf<InstalledApp?>(null) }
    var saving by remember { mutableStateOf<File?>(null) }
    val save = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/vnd.android.package-archive")) { uri ->
        val file = saving ?: return@rememberLauncherForActivityResult
        saving = null
        if (uri != null) store.scope.launch { copyToUri(context, file, uri) }
    }
    LaunchedEffect(model) { if (model.apps.isEmpty()) model.refresh() }

    val shown = model.apps.filter { app ->
        (showSystem || app.isLaunchable || !app.isSystem) &&
            (search.isBlank() || app.label.contains(search, true) || app.packageName.contains(search, true))
    }
    Box(Modifier.fillMaxSize()) {
        if (model.isLoading && model.apps.isEmpty()) LinearProgressIndicator(Modifier.fillMaxWidth())
        // Four to a row on phones (more on wide screens), every label two lines tall so rows line up.
        LazyVerticalGrid(
            GridCells.Adaptive(80.dp), Modifier.fillMaxSize(),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(start = 12.dp, end = 12.dp, top = 8.dp, bottom = 88.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            items(shown, key = { it.packageName }) { app ->
                Box {
                    Column(
                        Modifier.fillMaxWidth()
                            .clip(RoundedCornerShape(14.dp))
                            .combinedClickable(
                                onClick = { if (app.isLaunchable) store.scope.launch { model.open(app) } else menuFor = app },
                                onLongClick = { menuFor = app },
                            )
                            .semantics { contentDescription = app.label },
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        val icon = model.icons[app.packageName]
                        val iconModifier = Modifier.padding(top = 6.dp, bottom = 4.dp).size(48.dp)
                        if (icon != null) Image(icon.asImageBitmap(), null, iconModifier)
                        else Icon(Icons.Default.Android, null, iconModifier, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                        Text(app.label, Modifier.padding(horizontal = 2.dp, vertical = 2.dp), style = MaterialTheme.typography.labelSmall,
                            minLines = 2, maxLines = 2, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center)
                    }
                    DropdownMenu(expanded = menuFor == app, onDismissRequest = { menuFor = null }) {
                        Text("${app.label} ${app.versionName}", Modifier.padding(horizontal = 12.dp), style = MaterialTheme.typography.labelSmall)
                        if (app.isLaunchable) DropdownMenuItem(text = { Text("Open") }, onClick = {
                            menuFor = null
                            store.scope.launch { model.open(app) }
                        })
                        DropdownMenuItem(text = { Text("Force Stop") }, onClick = {
                            menuFor = null
                            store.scope.launch { model.stop(app) }
                        })
                        DropdownMenuItem(text = { Text("Save App File") }, onClick = {
                            menuFor = null
                            store.scope.launch {
                                val file = model.saveAppFile(app) ?: return@launch
                                saving = file
                                save.launch(file.name)
                            }
                        })
                        DropdownMenuItem(text = { Text("Uninstall", color = MaterialTheme.colorScheme.error) }, onClick = {
                            menuFor = null
                            confirmUninstall = app
                        })
                    }
                }
            }
        }
        StatusBanner(model.activity, model.error, model.message, Modifier.align(Alignment.BottomCenter)) {
            model.error = null
            model.message = null
        }
    }
    confirmUninstall?.let { app ->
        AlertDialog(
            onDismissRequest = { confirmUninstall = null },
            title = { Text("Uninstall ${app.label}?") },
            text = { if (app.isSystem) Text("It's a built-in app: it is removed for the current user and comes back after a factory reset.") },
            confirmButton = {
                TextButton(onClick = {
                    confirmUninstall = null
                    store.scope.launch { model.uninstall(app) }
                }) { Text("Uninstall", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { confirmUninstall = null }) { Text("Cancel") } },
        )
    }
}

fun displayName(context: Context, uri: Uri): String? =
    context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
        if (it.moveToFirst()) it.getString(0) else null
    }

suspend fun copyToCache(context: Context, uri: Uri, dir: File, name: String): File = withContext(Dispatchers.IO) {
    val file = File(dir, name)
    context.contentResolver.openInputStream(uri)!!.use { input -> file.outputStream().use { input.copyTo(it) } }
    file
}

suspend fun copyToUri(context: Context, file: File, uri: Uri) = withContext(Dispatchers.IO) {
    context.contentResolver.openOutputStream(uri)!!.use { out -> file.inputStream().use { it.copyTo(out) } }
    file.delete()
}
