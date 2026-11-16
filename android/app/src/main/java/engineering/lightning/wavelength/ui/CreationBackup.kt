package engineering.lightning.wavelength.ui

import android.view.WindowManager
import androidx.activity.compose.BackHandler
import androidx.activity.compose.LocalActivity
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp

/** Creation-only secrets never enter saved state, clipboard or a persistent file. */
@Composable internal fun CreationBackup(words: List<String>, done: () -> Unit) {
  SensitiveScreen()
  var revealed by remember { mutableStateOf(false) }
  var revealedOnce by remember { mutableStateOf(false) }
  var acknowledged by remember { mutableStateOf(false) }
  BackHandler {}
  Column(Modifier.fillMaxSize().systemBarsPadding().padding(24.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
    Text("Recovery words", style = MaterialTheme.typography.headlineMedium)
    Text("Shown once. Write them down and keep them offline.", color = MaterialTheme.colorScheme.onSurfaceVariant)
    Text("Recovery words alone may not recover off-chain funds.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    LazyVerticalGrid(GridCells.Fixed(2), Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(18.dp), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
      itemsIndexed(words) { index, word ->
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
          Text((index + 1).toString(), color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.labelSmall)
          Text(if (revealed) word else "••••••", fontFamily = FontFamily.Monospace)
        }
      }
    }
    TextButton({ revealed = !revealed; if (revealed) revealedOnce = true }) { Text(if (revealed) "Hide words" else "Reveal words") }
    Row(Modifier.fillMaxWidth().clickable(enabled = revealedOnce) { acknowledged = !acknowledged }, verticalAlignment = Alignment.CenterVertically) {
      Checkbox(acknowledged, { acknowledged = it }, enabled = revealedOnce); Text("I saved my recovery words")
    }
    WalletButton("Create wallet", revealedOnce && acknowledged, onClick = done)
  }
}

@Composable internal fun SensitiveScreen() {
  val activity = LocalActivity.current
  DisposableEffect(activity) {
    val wasSecure = activity?.window?.attributes?.flags?.and(WindowManager.LayoutParams.FLAG_SECURE) != 0
    activity?.window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    onDispose { if (!wasSecure) activity?.window?.clearFlags(WindowManager.LayoutParams.FLAG_SECURE) }
  }
}
