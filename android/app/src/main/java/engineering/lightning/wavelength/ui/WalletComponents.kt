package engineering.lightning.wavelength.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.foundation.clickable
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.text.NumberFormat

@Composable fun WalletButton(text: String, enabled: Boolean = true, secondary: Boolean = false, onClick: () -> Unit) {
  Button(onClick, Modifier.fillMaxWidth().heightIn(min = 54.dp), enabled = enabled,
    shape = RoundedCornerShape(15.dp),
    colors = if (secondary) ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.surface,
      contentColor = MaterialTheme.colorScheme.onSurface) else ButtonDefaults.buttonColors()) {
    Text(text, fontSize = 16.sp, fontWeight = FontWeight.Medium)
  }
}

@Composable fun Amount(amount: Long, modifier: Modifier = Modifier) {
  Row(modifier, verticalAlignment = androidx.compose.ui.Alignment.Bottom) {
    Text(NumberFormat.getIntegerInstance().format(amount), fontSize = 54.sp, letterSpacing = (-2).sp,
      fontWeight = FontWeight.Normal, lineHeight = 62.sp)
    Text("sats", Modifier.padding(start = 8.dp, bottom = 7.dp), fontSize = 22.sp,
      color = MaterialTheme.colorScheme.onSurfaceVariant)
  }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable fun WalletField(label: String, state: androidx.compose.foundation.text.input.TextFieldState,
  modifier: Modifier = Modifier, keyboardOptions: androidx.compose.foundation.text.KeyboardOptions = androidx.compose.foundation.text.KeyboardOptions.Default) {
  Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
    Text(label, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
    TextField(state = state, modifier = modifier.fillMaxWidth().semantics { contentDescription = label },
      lineLimits = androidx.compose.foundation.text.input.TextFieldLineLimits.MultiLine(maxHeightInLines = 4), shape = RoundedCornerShape(12.dp),
      keyboardOptions = keyboardOptions,
      colors = TextFieldDefaults.colors(focusedIndicatorColor = androidx.compose.ui.graphics.Color.Transparent,
        unfocusedIndicatorColor = androidx.compose.ui.graphics.Color.Transparent,
        focusedContainerColor = MaterialTheme.colorScheme.surface, unfocusedContainerColor = MaterialTheme.colorScheme.surface))
  }
}

/** Expandable details use a full-width Android list-row affordance. */
@Composable fun DetailSection(title: String = "Details", content: @Composable ColumnScope.() -> Unit) {
  var expanded by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(false) }
  val rotation by androidx.compose.animation.core.animateFloatAsState(if (expanded) 180f else 0f, label = "details chevron")
  Column {
    Row(Modifier.fillMaxWidth().heightIn(min = 56.dp)
      .clickable(role = androidx.compose.ui.semantics.Role.Button) { expanded = !expanded }
      .semantics { stateDescription = if (expanded) "Expanded" else "Collapsed" },
      verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
      Text(title, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge)
      Icon(androidx.compose.material.icons.Icons.Outlined.ExpandMore, null,
        Modifier.size(22.dp).rotate(rotation), tint = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    androidx.compose.animation.AnimatedVisibility(expanded) {
      Column(Modifier.fillMaxWidth().padding(top = 12.dp), verticalArrangement = Arrangement.spacedBy(20.dp), content = content)
    }
  }
}
