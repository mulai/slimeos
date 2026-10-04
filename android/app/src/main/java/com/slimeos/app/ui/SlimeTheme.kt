package com.slimeos.app.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.ExperimentalTextApi
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontVariation
import androidx.compose.ui.text.font.FontWeight
import com.slimeos.app.R

/**
 * The Membrane kiosk's design tokens (membrane/lockscreen/index.html, :root),
 * so the tablet looks like the same product. Change both together.
 */
object Slime {
    val Shell = Color(0xFF05080B)
    val Surface = Color(0xFF13191F)
    val Elevated = Color(0xFF1C2530)
    val Field = Color(0xFF0D1217)
    val Teal = Color(0xFF00C2A8)
    val TealDeep = Color(0xFF008B99)
    val Cyan = Color(0xFF00F2FE)
    val Mint = Color(0xFF5FE6D2)
    val AuroraBlue = Color(0xFF4FACFE)
    val AuroraGreen = Color(0xFF00FF87)
    val Title = Color(0xFFF2F6FB)
    val Text = Color(0xFFEAF1F7)
    val TextSoft = Color(0xFFC9D3DF)
    val TextMuted = Color(0xFF8B97A7)
    val TextHost = Color(0xFF7D8A9A)
    val TextDim = Color(0xFF56616F)
    val TextFaint = Color(0xFF3F4954)
    val Error = Color(0xFFFF8F8F)
    val Amber = Color(0xFFF5B955)
    val OnAccent = Color(0xFF04221F)

    // rgba(255,255,255,0.08 / 0.12 / 0.14 / 0.16): card, field, button, dashed borders.
    val Border = Color.White.copy(alpha = 0.08f)
    val BorderField = Color.White.copy(alpha = 0.12f)
    val BorderButton = Color.White.copy(alpha = 0.14f)
    val BorderDashed = Color.White.copy(alpha = 0.16f)

    /** .btn-primary / .seg-btn.active: linear-gradient(150deg, #00F2FE, #00C2A8). */
    val AccentGradient = Brush.linearGradient(listOf(Cyan, Teal))

    /** The Brain avatars' colours, in order (ACCENTS). */
    val Accents = listOf(Teal, AuroraBlue, AuroraGreen)

    @OptIn(ExperimentalTextApi::class)
    private fun variable(res: Int, weight: Int) = Font(
        res, FontWeight(weight),
        variationSettings = FontVariation.Settings(FontVariation.weight(weight))
    )

    /** --font-display: titles, buttons, tabs. */
    val Display = FontFamily(
        variable(R.font.space_grotesk, 400),
        variable(R.font.space_grotesk, 600),
        variable(R.font.space_grotesk, 700)
    )

    /** --font-body. */
    val Body = FontFamily(
        variable(R.font.plus_jakarta_sans, 400),
        variable(R.font.plus_jakarta_sans, 600),
        variable(R.font.plus_jakarta_sans, 700)
    )

    /** --font-mono: status strip, field labels, stages, technical details. */
    val Mono = FontFamily(
        variable(R.font.jetbrains_mono, 400),
        variable(R.font.jetbrains_mono, 600)
    )
}

@Composable
fun SlimeTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = darkColorScheme(
            primary = Slime.Teal,
            onPrimary = Slime.OnAccent,
            secondary = Slime.Mint,
            background = Slime.Shell,
            onBackground = Slime.Text,
            surface = Slime.Surface,
            onSurface = Slime.Text,
            surfaceVariant = Slime.Field,
            onSurfaceVariant = Slime.TextMuted,
            outline = Slime.BorderField,
            error = Slime.Error
        ),
        content = content
    )
}
