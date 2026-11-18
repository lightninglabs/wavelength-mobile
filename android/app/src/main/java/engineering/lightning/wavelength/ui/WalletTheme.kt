package engineering.lightning.wavelength.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.dp

private val Dark = darkColorScheme(
  background = Color(0xFF090A0C), onBackground = Color(0xFFF4F4F0),
  surface = Color(0xFF17191D), onSurface = Color(0xFFF4F4F0),
  surfaceVariant = Color(0xFF17191D), onSurfaceVariant = Color(0xFFA7AAAD),
  primary = Color(0xFFD6FF5F), onPrimary = Color(0xFF090A0C),
  primaryContainer = Color(0xFF303825), onPrimaryContainer = Color(0xFFD6FF5F),
  secondary = Color(0xFFD6FF5F), onSecondary = Color(0xFF090A0C),
  secondaryContainer = Color(0xFF303825), onSecondaryContainer = Color(0xFFD6FF5F),
  surfaceContainerHighest = Color(0xFF2B2D31), surfaceContainerHigh = Color(0xFF17191D),
  surfaceContainer = Color(0xFF17191D), surfaceContainerLow = Color(0xFF17191D),
  outline = Color(0xFF72757C),
  outlineVariant = Color(0xFF2B2D31),
)
private val Light = lightColorScheme(
  background = Color(0xFFFAFAFB), onBackground = Color(0xFF151518),
  surface = Color(0xFFF0F0F3), onSurface = Color(0xFF151518),
  surfaceVariant = Color(0xFFF0F0F3), onSurfaceVariant = Color(0xFF72757C),
  primary = Color(0xFF151518), onPrimary = Color.White,
  primaryContainer = Color(0xFFE4E5E8), onPrimaryContainer = Color(0xFF151518),
  secondary = Color(0xFF151518), onSecondary = Color.White,
  secondaryContainer = Color(0xFFE4E5E8), onSecondaryContainer = Color(0xFF151518),
  surfaceContainerHighest = Color(0xFFE4E5E8), surfaceContainerHigh = Color(0xFFF0F0F3),
  surfaceContainer = Color(0xFFF0F0F3), surfaceContainerLow = Color(0xFFF0F0F3),
  outline = Color(0xFF72757C),
  outlineVariant = Color(0xFFE4E5E8),
)

@Composable fun WalletTheme(dark: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
  MaterialTheme(colorScheme = if (dark) Dark else Light, content = content)
}

@Composable fun WaveMark(modifier: Modifier = Modifier.size(32.dp)) {
  val color = MaterialTheme.colorScheme.onBackground
  Canvas(modifier) {
    val y = size.height * .5f
    val path = Path().apply {
      moveTo(size.width * .04f, y)
      cubicTo(size.width * .22f, y - size.height * .21f, size.width * .28f, y - size.height * .21f, size.width * .5f, y)
      cubicTo(size.width * .72f, y + size.height * .21f, size.width * .78f, y + size.height * .21f, size.width * .96f, y)
    }
    drawPath(path, color, style = Stroke(width = size.width * .055f, cap = StrokeCap.Round))
  }
}
