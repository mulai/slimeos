package com.slimeos.app.ui

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.StartOffset
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.slimeos.app.R

// The kiosk's building blocks (.screen, .card, .btn-*, input.field, .brain-card,
// .ring-wrap, .error-card, .modal-card, ...), sized like the CSS.

/** .app: the shell with two soft glows, teal top-left and blue bottom-right. */
@Composable
fun SlimeBackground(content: @Composable BoxScope.() -> Unit) {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Slime.Shell)
            .drawBehind {
                val r = size.maxDimension
                drawRect(
                    Brush.radialGradient(
                        listOf(Slime.Teal.copy(alpha = 0.10f), Color.Transparent),
                        center = Offset(size.width * 0.15f, size.height * 0.10f),
                        radius = r * 0.9f
                    )
                )
                drawRect(
                    Brush.radialGradient(
                        listOf(Slime.AuroraBlue.copy(alpha = 0.08f), Color.Transparent),
                        center = Offset(size.width * 0.90f, size.height * 0.90f),
                        radius = r * 0.85f
                    )
                )
            },
        content = content
    )
}

enum class TunnelUi { Down, Connecting, Up }

/** .status-strip: brand on the left; tunnel, settings and signal bars on the right. */
@Composable
fun StatusStrip(tunnel: TunnelUi, pingMs: Long?, onSettings: (() -> Unit)?) {
    val mono = TextStyle(fontFamily = Slime.Mono, fontSize = 11.5.sp, letterSpacing = 0.5.sp)
    Row(
        modifier = Modifier.fillMaxWidth().height(48.dp).padding(horizontal = 22.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Image(
            painterResource(R.drawable.ic_slime_mark_white), contentDescription = null,
            modifier = Modifier.size(15.dp).graphicsLayer { alpha = 0.85f },
            colorFilter = ColorFilter.tint(Slime.TextMuted)
        )
        Spacer(Modifier.width(8.dp))
        Text("Slime OS", style = mono, color = Slime.TextMuted)
        Spacer(Modifier.weight(1f))

        val color = when (tunnel) {
            TunnelUi.Up -> Slime.AuroraGreen
            TunnelUi.Connecting -> Slime.Mint
            TunnelUi.Down -> Slime.TextDim
        }
        Box(
            Modifier.size(6.dp).drawBehind {
                drawCircle(color.copy(alpha = 0.35f), radius = size.minDimension)
                drawCircle(color)
            }
        )
        Spacer(Modifier.width(7.dp))
        Text(
            when (tunnel) {
                TunnelUi.Up -> "Secure tunnel"
                TunnelUi.Connecting -> "Connecting…"
                TunnelUi.Down -> "Not connected"
            },
            style = mono, color = color
        )
        if (onSettings != null) {
            Spacer(Modifier.width(14.dp))
            Box(
                Modifier.size(40.dp).clip(RoundedCornerShape(8.dp))
                    .clickable(role = Role.Button, onClickLabel = "Settings", onClick = onSettings),
                contentAlignment = Alignment.Center
            ) {
                Image(
                    painterResource(R.drawable.ic_settings_gear), contentDescription = "Settings",
                    modifier = Modifier.size(17.dp), colorFilter = ColorFilter.tint(Slime.TextMuted)
                )
            }
        }
        Spacer(Modifier.width(10.dp))
        SignalBars(level = signalLevel(tunnel, pingMs))
    }
}

// Same thresholds as the kiosk's tunnelBarLevel().
private fun signalLevel(tunnel: TunnelUi, ms: Long?): Int = when {
    tunnel != TunnelUi.Up || ms == null -> 0
    ms < 80 -> 3
    ms < 200 -> 2
    ms < 400 -> 1
    else -> 0
}

@Composable
private fun SignalBars(level: Int) {
    Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        listOf(4.dp, 7.dp, 11.dp).forEachIndexed { i, h ->
            Box(
                Modifier.width(3.dp).height(h).clip(RoundedCornerShape(1.dp)).background(
                    if (i < level) Slime.Mint else Slime.TextMuted.copy(alpha = 0.25f)
                )
            )
        }
    }
}

/** The colour mark; [drip] for the welcome screen, without it elsewhere (slimeBlobSVG). */
@Composable
fun SlimeMark(size: Dp, drip: Boolean = false, float: Boolean = false) {
    var modifier = Modifier.width(size).height(if (drip) size * (106f / 88f) else size)
    if (float) {
        // blobFloat: 6 s up-and-down by 6px.
        val t = rememberInfiniteTransition(label = "float")
        val y by t.animateFloat(
            0f, -6f,
            infiniteRepeatable(tween(3_000), RepeatMode.Reverse), label = "y"
        )
        modifier = modifier.graphicsLayer { translationY = y * density }
    }
    Image(
        painterResource(if (drip) R.drawable.ic_slime_mark else R.drawable.ic_slime_mark_nodrip),
        contentDescription = null, modifier = modifier
    )
}

/** .screen: a centred column that fades up on entry. */
@Composable
fun SlimeScreen(
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit
) {
    Column(
        modifier = modifier.fillMaxWidth().padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
        content = content
    )
}

/** .card: the 400-wide form card. */
@Composable
fun SlimeCard(
    maxWidth: Dp = 400.dp,
    border: Color = Slime.Border,
    padding: Dp = 36.dp,
    content: @Composable ColumnScope.() -> Unit
) {
    Column(
        modifier = Modifier
            .widthIn(max = maxWidth).fillMaxWidth()
            .clip(RoundedCornerShape(20.dp))
            .background(Slime.Surface)
            .border(1.dp, border, RoundedCornerShape(20.dp))
            .padding(padding),
        content = content
    )
}

@Composable
fun ScreenTitle(text: String, size: TextUnit = 34.sp) {
    Text(
        text, textAlign = TextAlign.Center, color = Slime.Title,
        style = TextStyle(
            fontFamily = Slime.Display, fontWeight = FontWeight.Bold,
            fontSize = size, letterSpacing = (-0.02f * size.value).sp
        )
    )
}

/** h2.title inside a card. */
@Composable
fun CardTitle(text: String) {
    Text(
        text, color = Slime.Title,
        style = TextStyle(fontFamily = Slime.Display, fontWeight = FontWeight.Bold, fontSize = 21.sp)
    )
}

@Composable
fun Muted(
    text: String,
    modifier: Modifier = Modifier,
    size: TextUnit = 13.5.sp,
    color: Color = Slime.TextMuted,
    align: TextAlign = TextAlign.Start
) {
    Text(
        text, modifier = modifier, color = color, textAlign = align,
        style = TextStyle(fontFamily = Slime.Body, fontSize = size, lineHeight = size * 1.6f)
    )
}

/** p.subtitle under a screen title. */
@Composable
fun Subtitle(text: String) {
    Text(
        text, textAlign = TextAlign.Center, color = Slime.TextMuted,
        modifier = Modifier.widthIn(max = 420.dp).padding(top = 16.dp),
        style = TextStyle(fontFamily = Slime.Body, fontSize = 15.5.sp, lineHeight = 25.sp)
    )
}

/** Mono, mint: the connecting screens' stage line. */
@Composable
fun StageText(text: String) {
    Text(
        text, color = Slime.Mint, textAlign = TextAlign.Center,
        modifier = Modifier.widthIn(max = 520.dp),
        style = TextStyle(fontFamily = Slime.Mono, fontSize = 14.5.sp, lineHeight = 22.sp)
    )
}

/** .btn-primary: the cyan-to-teal gradient button. */
@Composable
fun PrimaryButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    large: Boolean = false
) {
    Box(
        modifier = modifier
            .clip(RoundedCornerShape(12.dp))
            .background(Slime.AccentGradient, alpha = if (enabled) 1f else 0.45f)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(horizontal = if (large) 30.dp else 20.dp, vertical = if (large) 15.dp else 13.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text, color = Slime.OnAccent, maxLines = 1,
            style = TextStyle(fontFamily = Slime.Display, fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
        )
    }
}

/** .btn-secondary: outlined. */
@Composable
fun SecondaryButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .clip(RoundedCornerShape(10.dp))
            .border(1.dp, Slime.BorderButton, RoundedCornerShape(10.dp))
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 22.dp, vertical = 13.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text, color = Slime.TextSoft, maxLines = 1,
            style = TextStyle(fontFamily = Slime.Display, fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
        )
    }
}

/** .btn-tertiary: text only. */
@Composable
fun TertiaryButton(text: String, onClick: () -> Unit, color: Color = Slime.TextMuted) {
    Box(
        Modifier.clip(RoundedCornerShape(8.dp)).clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 10.dp)
    ) {
        Text(
            text, color = color,
            style = TextStyle(fontFamily = Slime.Display, fontWeight = FontWeight.SemiBold, fontSize = 13.5.sp)
        )
    }
}

/** .btn-ghost: small mono capitals. */
@Composable
fun GhostButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Box(
        modifier.clip(RoundedCornerShape(6.dp)).clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 10.dp)
    ) {
        Text(text.uppercase(), color = Slime.TextDim, style = ghostStyle)
    }
}

@Composable
fun GhostLabel(text: String) {
    Text(text.uppercase(), color = Slime.TextDim, style = ghostStyle, modifier = Modifier.padding(8.dp))
}

private val ghostStyle = TextStyle(fontFamily = Slime.Mono, fontSize = 11.sp, letterSpacing = 1.5.sp)

/** The red Remove/Forget button in the kiosk's confirm modals. */
@Composable
fun DangerButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .clip(RoundedCornerShape(10.dp))
            .background(Color(0xFF3A1414))
            .border(1.dp, Color(0x4DFF6B6B), RoundedCornerShape(10.dp))
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 18.dp, vertical = 12.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text, color = Slime.Error, maxLines = 1,
            style = TextStyle(fontFamily = Slime.Display, fontWeight = FontWeight.SemiBold, fontSize = 13.5.sp)
        )
    }
}

/** label.field-label + input.field. */
@Composable
fun SlimeField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    placeholder: String = "",
    password: Boolean = false,
    mono: Boolean = false,
    error: Boolean = false,
    keyboardType: KeyboardType = KeyboardType.Text,
    capitalization: KeyboardCapitalization = KeyboardCapitalization.None,
    imeAction: ImeAction = ImeAction.Next,
    onImeDone: (() -> Unit)? = null,
    bottomGap: Dp = 18.dp
) {
    var focused by remember { mutableStateOf(false) }
    var shown by remember { mutableStateOf(false) }
    Column(modifier.fillMaxWidth().padding(bottom = bottomGap)) {
        Text(
            label.uppercase(), color = Slime.Mint, modifier = Modifier.padding(bottom = 8.dp),
            style = TextStyle(fontFamily = Slime.Mono, fontSize = 10.5.sp, letterSpacing = 1.5.sp)
        )
        val borderColor = when {
            error -> Slime.Error
            focused -> Slime.Teal
            else -> Slime.BorderField
        }
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            singleLine = true,
            cursorBrush = SolidColor(Slime.Teal),
            textStyle = TextStyle(
                fontFamily = if (mono) Slime.Mono else Slime.Body, fontSize = 15.sp, color = Slime.Text
            ),
            visualTransformation = if (password && !shown) PasswordVisualTransformation() else VisualTransformation.None,
            keyboardOptions = KeyboardOptions(
                keyboardType = if (password) KeyboardType.Password else keyboardType,
                capitalization = capitalization,
                autoCorrectEnabled = false,
                imeAction = imeAction
            ),
            keyboardActions = KeyboardActions(onDone = { onImeDone?.invoke() }, onGo = { onImeDone?.invoke() }),
            modifier = Modifier.fillMaxWidth().onFocusChanged { focused = it.isFocused },
            decorationBox = { inner ->
                Row(
                    Modifier.fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(Slime.Field)
                        .border(1.dp, borderColor, RoundedCornerShape(10.dp))
                        .padding(start = 14.dp, end = if (password) 4.dp else 14.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Box(Modifier.weight(1f).padding(vertical = 14.dp)) {
                        if (value.isEmpty() && placeholder.isNotEmpty()) {
                            Text(
                                placeholder, color = Slime.TextDim, maxLines = 1,
                                style = TextStyle(fontFamily = if (mono) Slime.Mono else Slime.Body, fontSize = 15.sp)
                            )
                        }
                        inner()
                    }
                    if (password) {
                        Box(
                            Modifier.clip(RoundedCornerShape(6.dp))
                                .clickable(role = Role.Button) { shown = !shown }
                                .padding(horizontal = 10.dp, vertical = 10.dp)
                        ) {
                            Text(
                                if (shown) "HIDE" else "SHOW", color = Slime.TextHost,
                                style = TextStyle(fontFamily = Slime.Mono, fontSize = 10.5.sp, letterSpacing = 0.5.sp)
                            )
                        }
                    }
                }
            }
        )
    }
}

/** The form's inline error line under a field. */
@Composable
fun FieldError(text: String?) {
    Text(
        text ?: "", color = Slime.Error, modifier = Modifier.padding(top = 2.dp, bottom = 6.dp),
        style = TextStyle(fontFamily = Slime.Body, fontSize = 12.5.sp)
    )
}

/** .ring-wrap: the mark with two rings pulsing out of it. */
@Composable
fun PulsingMark() {
    val t = rememberInfiniteTransition(label = "pulse")
    @Composable
    fun ring(delayMs: Int) = t.animateFloat(
        0f, 1f,
        infiniteRepeatable(tween(2_200, easing = LinearEasing), initialStartOffset = StartOffset(delayMs)),
        label = "ring$delayMs"
    )
    val outer by ring(0)
    val inner by ring(600)
    Box(Modifier.size(120.dp), contentAlignment = Alignment.Center) {
        Canvas(Modifier.fillMaxSize()) {
            // pulseRing: scale 0.85 -> 1.35, opacity 0.55 -> 0 by 70 %, then nothing.
            fun draw(p: Float, inset: Float) {
                val k = (p / 0.7f).coerceAtMost(1f)
                val alpha = if (p < 0.7f) 0.55f * (1f - k) else 0f
                val scale = 0.85f + 0.5f * k
                val r = (size.minDimension / 2f - inset) * scale
                drawCircle(Slime.Teal.copy(alpha = alpha * 0.9f), radius = r, style = Stroke(2.dp.toPx()))
            }
            draw(outer, 0f)
            draw(inner, 14.dp.toPx())
        }
        SlimeMark(66.dp)
    }
}

/** .spinner. */
@Composable
fun Spinner(size: Dp = 26.dp) {
    val t = rememberInfiniteTransition(label = "spin")
    val angle by t.animateFloat(
        0f, 360f, infiniteRepeatable(tween(900, easing = LinearEasing)), label = "angle"
    )
    Canvas(Modifier.size(size)) {
        val stroke = Stroke(2.dp.toPx())
        drawCircle(Slime.Teal.copy(alpha = 0.3f), style = stroke)
        drawArc(Slime.Teal, angle, 90f, useCenter = false, style = stroke)
    }
}

enum class BadgeKind { Asleep, Offline, SlimeId }

@Composable
fun Badge(kind: BadgeKind) {
    val (text, fg, bg) = when (kind) {
        BadgeKind.Asleep -> Triple("Asleep", Slime.Amber, Slime.Amber.copy(alpha = 0.12f))
        BadgeKind.Offline -> Triple("Offline", Slime.TextDim, Slime.TextDim.copy(alpha = 0.18f))
        BadgeKind.SlimeId -> Triple("Slime ID", Slime.Mint, Slime.Teal.copy(alpha = 0.12f))
    }
    Text(
        text.uppercase(), color = fg,
        modifier = Modifier.padding(start = 6.dp).clip(RoundedCornerShape(5.dp)).background(bg)
            .padding(horizontal = 6.dp, vertical = 2.dp),
        style = TextStyle(fontFamily = Slime.Body, fontWeight = FontWeight.SemiBold, fontSize = 9.5.sp, letterSpacing = 0.3.sp)
    )
}

/** .brain-card. */
@Composable
fun BrainCard(
    name: String,
    host: String,
    accent: Color,
    meta: String,
    action: String,
    badge: BadgeKind?,
    onClick: () -> Unit,
    onRemove: (() -> Unit)?
) {
    Column(
        Modifier.width(300.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(Slime.Surface)
            .border(1.dp, Slime.Border, RoundedCornerShape(16.dp))
            .clickable(role = Role.Button, onClick = onClick)
            .padding(20.dp)
    ) {
        Row(verticalAlignment = Alignment.Top) {
            Box(
                Modifier.size(40.dp).clip(RoundedCornerShape(11.dp)).background(accent),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    name.trim().take(1).uppercase().ifEmpty { "?" }, color = Slime.OnAccent,
                    style = TextStyle(fontFamily = Slime.Display, fontWeight = FontWeight.Bold, fontSize = 16.sp)
                )
            }
            Column(Modifier.weight(1f).padding(start = 12.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        name, color = Slime.Text, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                        style = TextStyle(fontFamily = Slime.Display, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                    )
                    badge?.let { Badge(it) }
                }
                Text(
                    host, color = Slime.TextHost, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = 2.dp),
                    style = TextStyle(fontFamily = Slime.Mono, fontSize = 11.sp)
                )
            }
            if (onRemove != null) {
                Box(
                    Modifier.size(36.dp).clip(RoundedCornerShape(8.dp))
                        .clickable(role = Role.Button, onClickLabel = "Remove", onClick = onRemove),
                    contentAlignment = Alignment.Center
                ) {
                    Text("×", color = Slime.TextDim, fontSize = 19.sp)
                }
            }
        }
        Row(Modifier.fillMaxWidth().padding(top = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(
                meta, color = Slime.TextFaint, modifier = Modifier.weight(1f),
                style = TextStyle(fontFamily = Slime.Body, fontSize = 11.5.sp)
            )
            Text(
                action, color = Slime.Mint,
                style = TextStyle(fontFamily = Slime.Display, fontWeight = FontWeight.SemiBold, fontSize = 13.sp)
            )
        }
    }
}

/** .add-card: dashed "+ Add a Brain". */
@Composable
fun AddCard(text: String, onClick: () -> Unit) {
    Row(
        Modifier.width(300.dp).height(112.dp)
            .clip(RoundedCornerShape(16.dp))
            .drawBehind {
                drawRoundRect(
                    Slime.BorderDashed, cornerRadius = CornerRadius(16.dp.toPx()),
                    style = Stroke(1.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(10f, 8f)))
                )
            }
            .clickable(role = Role.Button, onClick = onClick),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text("+", color = Slime.TextMuted, fontSize = 20.sp)
        Spacer(Modifier.width(10.dp))
        Text(
            text, color = Slime.TextMuted,
            style = TextStyle(fontFamily = Slime.Display, fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
        )
    }
}

/** .error-card with "+ Technical details". */
@Composable
fun ErrorCard(
    title: String,
    body: String?,
    detail: String?,
    actions: @Composable ColumnScope.() -> Unit
) {
    var showDetail by remember { mutableStateOf(false) }
    SlimeCard(maxWidth = 440.dp, border = Color(0x2EFF6F6F)) {
        Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
            Box(
                Modifier.size(52.dp).clip(CircleShape).background(Color(0x1FFF6B6B)),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    "!", color = Slime.Error,
                    style = TextStyle(fontFamily = Slime.Display, fontWeight = FontWeight.Bold, fontSize = 24.sp)
                )
            }
            Text(
                title, color = Slime.Title, textAlign = TextAlign.Center,
                modifier = Modifier.padding(top = 20.dp),
                style = TextStyle(fontFamily = Slime.Display, fontWeight = FontWeight.Bold, fontSize = 19.sp, lineHeight = 25.sp)
            )
            if (!body.isNullOrEmpty()) {
                Muted(body, Modifier.padding(top = 10.dp), align = TextAlign.Center)
            }
            Column(
                Modifier.fillMaxWidth().padding(top = 28.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                content = actions
            )
            if (!detail.isNullOrEmpty()) {
                Column(
                    Modifier.fillMaxWidth().padding(top = 24.dp)
                        .drawBehind {
                            drawLine(
                                Slime.Border, Offset.Zero, Offset(size.width, 0f), 1.dp.toPx(),
                                pathEffect = PathEffect.dashPathEffect(floatArrayOf(6f, 6f))
                            )
                        }
                        .padding(top = 14.dp)
                ) {
                    Text(
                        (if (showDetail) "− " else "+ ") + "Technical details", color = Slime.TextDim,
                        modifier = Modifier.clickable(
                            interactionSource = remember { MutableInteractionSource() }, indication = null
                        ) { showDetail = !showDetail },
                        style = TextStyle(fontFamily = Slime.Mono, fontSize = 10.5.sp, letterSpacing = 1.sp)
                    )
                    if (showDetail) {
                        Text(
                            detail, color = Slime.TextDim,
                            modifier = Modifier.padding(top = 8.dp).fillMaxWidth()
                                .clip(RoundedCornerShape(8.dp)).background(Slime.Field)
                                .padding(horizontal = 12.dp, vertical = 10.dp),
                            style = TextStyle(fontFamily = Slime.Mono, fontSize = 11.sp)
                        )
                    }
                }
            }
        }
    }
}

/** .modal-overlay + .modal-card. */
@Composable
fun SlimeModal(onDismiss: () -> Unit, content: @Composable ColumnScope.() -> Unit) {
    Box(
        Modifier.fillMaxSize().background(Color(0x99040608))
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onDismiss),
        contentAlignment = Alignment.Center
    ) {
        Column(
            Modifier.padding(24.dp).widthIn(max = 380.dp).fillMaxWidth()
                .clip(RoundedCornerShape(16.dp)).background(Slime.Surface)
                .border(1.dp, Slime.BorderButton, RoundedCornerShape(16.dp))
                // Taps inside the card don't dismiss it.
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {}
                .padding(28.dp),
            content = content
        )
    }
}

@Composable
fun ModalTitle(text: String) {
    Text(
        text, color = Slime.Title, modifier = Modifier.padding(bottom = 10.dp),
        style = TextStyle(fontFamily = Slime.Display, fontWeight = FontWeight.Bold, fontSize = 16.5.sp)
    )
}

/** .support-toggle-row: the whole row is the switch. */
@Composable
fun ToggleRow(title: String, subtitle: String?, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(Slime.Field)
            .border(1.dp, Slime.BorderField, RoundedCornerShape(12.dp))
            .clickable(role = Role.Switch) { onChange(!checked) }
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(Modifier.weight(1f)) {
            Text(
                title, color = Slime.Text,
                style = TextStyle(fontFamily = Slime.Display, fontWeight = FontWeight.SemiBold, fontSize = 14.5.sp)
            )
            if (subtitle != null) Muted(subtitle, Modifier.padding(top = 4.dp), size = 12.sp)
        }
        Spacer(Modifier.width(16.dp))
        SlimeSwitch(checked)
    }
}

@Composable
private fun SlimeSwitch(checked: Boolean) {
    Box(
        Modifier.width(42.dp).height(24.dp).clip(CircleShape)
            .background(if (checked) Slime.AccentGradient else SolidColor(Color.White.copy(alpha = 0.12f)))
            .padding(3.dp),
        contentAlignment = if (checked) Alignment.CenterEnd else Alignment.CenterStart
    ) {
        Box(Modifier.size(18.dp).clip(CircleShape).background(if (checked) Slime.OnAccent else Slime.TextMuted))
    }
}

/** A label/value list like the Remote Support tab's connection box. */
@Composable
fun InfoBox(rows: List<Pair<String, String>>) {
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(Slime.Field)
            .border(1.dp, Slime.Teal.copy(alpha = 0.25f), RoundedCornerShape(12.dp))
            .padding(18.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        rows.forEach { (k, v) ->
            Row {
                Text(k, color = Slime.TextDim, modifier = Modifier.width(120.dp), style = TextStyle(fontFamily = Slime.Mono, fontSize = 13.sp))
                Text(v, color = Slime.Mint, style = TextStyle(fontFamily = Slime.Mono, fontSize = 13.sp))
            }
        }
    }
}

/** .seg-group / .seg-btn: pick one, as on the kiosk's Display & Sound tab. */
@Composable
fun SegmentedRow(label: String, options: List<String>, selected: Int, onSelect: (Int) -> Unit) {
    Column {
        Text(
            label.uppercase(), color = Slime.Mint, modifier = Modifier.padding(bottom = 8.dp),
            style = TextStyle(fontFamily = Slime.Mono, fontSize = 10.5.sp, letterSpacing = 1.5.sp)
        )
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            options.forEachIndexed { i, option ->
                val active = i == selected
                Box(
                    Modifier.clip(RoundedCornerShape(10.dp))
                        .background(if (active) Slime.AccentGradient else SolidColor(Slime.Field))
                        .border(1.dp, if (active) Color.Transparent else Slime.BorderField, RoundedCornerShape(10.dp))
                        .clickable(role = Role.RadioButton) { onSelect(i) }
                        .padding(horizontal = 18.dp, vertical = 11.dp)
                ) {
                    Text(
                        option, color = if (active) Slime.OnAccent else Slime.TextMuted,
                        style = TextStyle(fontFamily = Slime.Display, fontWeight = FontWeight.SemiBold, fontSize = 13.5.sp)
                    )
                }
            }
        }
    }
}

/** textarea.field: several lines, same look as SlimeField. */
@Composable
fun SlimeTextArea(label: String, value: String, onValueChange: (String) -> Unit, placeholder: String = "") {
    var focused by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth()) {
        Text(
            label.uppercase(), color = Slime.Mint, modifier = Modifier.padding(bottom = 8.dp),
            style = TextStyle(fontFamily = Slime.Mono, fontSize = 10.5.sp, letterSpacing = 1.5.sp)
        )
        BasicTextField(
            value = value,
            onValueChange = { onValueChange(it.take(4000)) },
            cursorBrush = SolidColor(Slime.Teal),
            textStyle = TextStyle(fontFamily = Slime.Body, fontSize = 15.sp, lineHeight = 22.sp, color = Slime.Text),
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
            modifier = Modifier.fillMaxWidth().onFocusChanged { focused = it.isFocused },
            decorationBox = { inner ->
                Box(
                    Modifier.fillMaxWidth().height(132.dp)
                        .clip(RoundedCornerShape(10.dp)).background(Slime.Field)
                        .border(1.dp, if (focused) Slime.Teal else Slime.BorderField, RoundedCornerShape(10.dp))
                        .padding(horizontal = 14.dp, vertical = 12.dp)
                ) {
                    if (value.isEmpty() && placeholder.isNotEmpty()) {
                        Text(placeholder, color = Slime.TextDim, style = TextStyle(fontFamily = Slime.Body, fontSize = 15.sp))
                    }
                    inner()
                }
            }
        )
    }
}
