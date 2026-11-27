package engineering.lightning.wavelength.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import engineering.lightning.wavewalletdk.client.WalletVTXO
import engineering.lightning.wavelength.data.sats
import engineering.lightning.wavelength.data.shortId

@Composable internal fun FundPage(modifier: Modifier, content: @Composable ColumnScope.() -> Unit) {
  FundPage(modifier, footer = null, content = content)
}

/** The wallet page uses the same reading width and spacing as the iOS funds screens. */
@Composable internal fun FundPage(
  modifier: Modifier,
  footer: (@Composable ColumnScope.() -> Unit)?,
  content: @Composable ColumnScope.() -> Unit,
) {
  Column(modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally) {
    Column(Modifier.weight(1f).widthIn(max = 620.dp).fillMaxWidth().verticalScroll(rememberScrollState())
      .padding(start = 24.dp, end = 24.dp, top = 24.dp, bottom = 32.dp),
      verticalArrangement = Arrangement.spacedBy(28.dp), content = content)
    if (footer != null) {
      Column(Modifier.widthIn(max = 620.dp).fillMaxWidth().padding(horizontal = 24.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp), content = footer)
    }
  }
}

@Composable internal fun FundChoice(fund: WalletVTXO, selected: Boolean, enabled: Boolean, single: Boolean = false,
  onChange: (Boolean) -> Unit) {
  Row(Modifier.fillMaxWidth().heightIn(min = 64.dp)
    .toggleable(selected, enabled, role = if (single) Role.RadioButton else Role.Checkbox, onValueChange = onChange)
    .padding(vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
      Text(sats(fund.amountSat), style = MaterialTheme.typography.bodyLarge)
      Text(shortId(fund.outpoint), style = MaterialTheme.typography.labelSmall, fontFamily = FontFamily.Monospace,
        maxLines = 1, overflow = TextOverflow.Ellipsis, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    if (single) RadioButton(selected, null, enabled = enabled)
    else Checkbox(selected, null, enabled = enabled)
  }
  HorizontalDivider()
}

@Composable internal fun WalletToggle(label: String, checked: Boolean, enabled: Boolean, change: (Boolean) -> Unit) {
  Row(Modifier.fillMaxWidth().heightIn(min = 52.dp).toggleable(checked, enabled = enabled, role = Role.Switch, onValueChange = change),
    verticalAlignment = Alignment.CenterVertically) {
    Text(label, Modifier.weight(1f))
    Switch(checked, null, enabled = enabled)
  }
}
