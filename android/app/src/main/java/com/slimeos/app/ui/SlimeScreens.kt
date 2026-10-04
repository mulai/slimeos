package com.slimeos.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.slimeos.app.AppLock
import com.slimeos.app.BrainPower
import com.slimeos.app.SavedPairing
import kotlinx.coroutines.delay

// One composable per kiosk screen (lockscreen/index.html's render*()), same
// copy where the flow is the same.

private val HOST_RE = Regex(
    "^(?:(?:\\d{1,3}\\.){3}\\d{1,3}|[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?" +
        "(?:\\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*)$"
)

/** renderEmpty. */
@Composable
fun WelcomeScreen(onAddBrain: () -> Unit) {
    SlimeScreen {
        SlimeMark(96.dp, drip = true, float = true)
        Spacer(Modifier.height(24.dp))
        ScreenTitle("Welcome to Slime OS")
        Subtitle(
            "Your Brain is a computer in the cloud that does the heavy lifting. " +
                "Add one so this tablet can connect to it."
        )
        Spacer(Modifier.height(36.dp))
        PrimaryButton("Add a Brain", onAddBrain, large = true)
    }
}

/** renderPairEntry. */
@Composable
fun PairScreen(hint: String?, onPair: (host: String, code: String) -> Unit, onBack: (() -> Unit)?) {
    var host by remember { mutableStateOf("enroll.slimeos.com") }
    var code by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    val submit = {
        val h = host.trim()
        when {
            !HOST_RE.matches(h) -> error = "Enter a valid host, e.g. enroll.slimeos.com"
            code.isBlank() -> error = "Enter the pairing code."
            else -> {
                error = null
                onPair(h, code.trim().uppercase())
            }
        }
    }
    SlimeScreen {
        SlimeCard {
            CardTitle("Pair with a Brain")
            if (hint != null) Muted(hint, Modifier.padding(top = 6.dp), color = Slime.Mint)
            Muted(
                "Enter the enrollment address and the code your admin gave you.",
                Modifier.padding(top = 6.dp, bottom = 26.dp)
            )
            SlimeField("Enrollment host", host, { host = it }, placeholder = "e.g. enroll.slimeos.com", keyboardType = KeyboardType.Uri)
            SlimeField(
                "Pairing code", code, { code = it }, placeholder = "XXXX-XXXX", mono = true,
                capitalization = KeyboardCapitalization.Characters,
                imeAction = ImeAction.Go, onImeDone = submit, bottomGap = 0.dp
            )
            FieldError(error)
            Row(Modifier.fillMaxWidth().padding(top = 16.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                if (onBack != null) SecondaryButton("Back", onBack, Modifier.weight(1f))
                PrimaryButton("Pair", submit, Modifier.weight(1.4f))
            }
        }
    }
}

/** renderPairConnecting / renderWifiConnecting: ring, title, stage, no buttons. */
@Composable
fun WorkingScreen(title: String, stage: String) {
    SlimeScreen {
        PulsingMark()
        Spacer(Modifier.height(30.dp))
        CardTitle(title)
        Spacer(Modifier.height(12.dp))
        StageText(stage)
    }
}

/** renderAddBrain. */
@Composable
fun AddBrainScreen(
    initialName: String,
    initialHost: String,
    initialPort: Int,
    onContinue: (name: String, host: String, port: Int) -> Unit,
    onCancel: () -> Unit
) {
    var name by remember { mutableStateOf(initialName) }
    var host by remember { mutableStateOf(initialHost) }
    var port by remember { mutableStateOf(initialPort.toString()) }
    var advanced by remember { mutableStateOf(initialPort != 3389) }
    var error by remember { mutableStateOf<String?>(null) }
    val submit = {
        val h = host.trim()
        val p = port.trim().toIntOrNull()
        when {
            !HOST_RE.matches(h) -> error = "Enter a valid IP address or hostname."
            p == null || p !in 1..65535 -> error = "Port must be between 1 and 65535."
            else -> {
                error = null
                onContinue(name.trim().ifEmpty { SavedPairing.DEFAULT_BRAIN_NAME }, h, p)
            }
        }
    }
    SlimeScreen {
        SlimeCard {
            CardTitle("Add a Brain")
            Muted("Enter its name and address to connect.", Modifier.padding(top = 6.dp, bottom = 26.dp))
            SlimeField("Name", name, { name = it }, placeholder = "e.g. Home Office", capitalization = KeyboardCapitalization.Words)
            SlimeField(
                "Address", host, { host = it; error = null }, placeholder = "IP address or hostname",
                keyboardType = KeyboardType.Uri, error = error != null && !advanced,
                imeAction = if (advanced) ImeAction.Next else ImeAction.Go, onImeDone = submit, bottomGap = 0.dp
            )
            FieldError(error)
            if (!advanced) {
                GhostButton("+ Advanced (port)", { advanced = true }, Modifier.padding(top = 2.dp))
            } else {
                Box(Modifier.width(140.dp).padding(top = 8.dp)) {
                    SlimeField(
                        "Port", port, { port = it.filter(Char::isDigit).take(5) }, mono = true,
                        keyboardType = KeyboardType.Number, imeAction = ImeAction.Go, onImeDone = submit, bottomGap = 0.dp
                    )
                }
            }
            Row(Modifier.fillMaxWidth().padding(top = 30.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                SecondaryButton("Cancel", onCancel, Modifier.weight(1f))
                PrimaryButton("Continue", submit, Modifier.weight(1.4f))
            }
        }
    }
}

/** renderCredentials. */
@Composable
fun CredentialsScreen(
    brainName: String,
    initialUsername: String,
    onConnect: (username: String, password: String) -> Unit,
    onBack: () -> Unit
) {
    var username by remember { mutableStateOf(initialUsername) }
    var password by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    val submit = {
        when {
            username.isBlank() -> error = "Enter the Windows username."
            password.isEmpty() -> error = "Enter the password."
            else -> onConnect(username.trim(), password)
        }
    }
    SlimeScreen {
        SlimeCard {
            CardTitle("Who signs in on $brainName?")
            Muted(
                "We’ll remember this, stored securely on this tablet.",
                Modifier.padding(top = 6.dp, bottom = 26.dp)
            )
            SlimeField("Username", username, { username = it; error = null }, placeholder = "e.g. jane")
            SlimeField(
                "Password", password, { password = it; error = null }, placeholder = "Password",
                password = true, imeAction = ImeAction.Go, onImeDone = submit, bottomGap = 0.dp
            )
            FieldError(error)
            Row(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                SecondaryButton("Back", onBack, Modifier.weight(1f))
                PrimaryButton("Connect", submit, Modifier.weight(1.4f))
            }
        }
    }
}

/** renderPicker, for the one Brain this app keeps. */
@Composable
fun PickerScreen(
    name: String,
    host: String,
    status: BrainPower.Status?,
    notice: String?,
    onConnect: () -> Unit,
    onRemove: () -> Unit
) {
    SlimeScreen {
        SlimeMark(52.dp)
        Spacer(Modifier.height(20.dp))
        ScreenTitle("Choose a Brain", size = 26.sp)
        Muted("Tap a card to connect", Modifier.padding(top = 4.dp, bottom = 32.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterHorizontally)) {
            BrainCard(
                name = name,
                host = host,
                accent = Slime.Accents[0],
                meta = when (status) {
                    BrainPower.Status.Asleep -> "Wakes up when you connect"
                    BrainPower.Status.Offline -> "Not reachable right now"
                    else -> "Saved on this tablet"
                },
                action = "Connect →",
                badge = when (status) {
                    BrainPower.Status.Asleep -> BadgeKind.Asleep
                    BrainPower.Status.Offline -> BadgeKind.Offline
                    else -> null
                },
                onClick = onConnect,
                onRemove = onRemove
            )
        }
        if (notice != null) {
            Muted(notice, Modifier.padding(top = 28.dp).widthIn(max = 460.dp), align = TextAlign.Center)
        }
    }
}

/** renderConnecting. */
@Composable
fun ConnectingScreen(brainName: String, stage: String, onCancel: () -> Unit) {
    SlimeScreen {
        PulsingMark()
        Spacer(Modifier.height(30.dp))
        CardTitle(brainName)
        Spacer(Modifier.height(12.dp))
        StageText(stage)
        Spacer(Modifier.height(34.dp))
        SecondaryButton("Cancel", onCancel)
    }
}

/** renderReconnecting. */
@Composable
fun ReconnectingScreen(attempt: Int, stage: String?, onBack: () -> Unit) {
    SlimeScreen {
        Column(
            Modifier.widthIn(max = 380.dp).clip(RoundedCornerShape(18.dp))
                .background(Slime.Shell.copy(alpha = 0.92f))
                .border(1.dp, Slime.BorderField, RoundedCornerShape(18.dp))
                .padding(horizontal = 40.dp, vertical = 34.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Spinner()
            Text(
                "Connection lost — reconnecting…", color = Slime.Title, textAlign = TextAlign.Center,
                modifier = Modifier.padding(top = 18.dp),
                style = TextStyle(fontFamily = Slime.Display, fontWeight = FontWeight.SemiBold, fontSize = 17.sp)
            )
            Text(
                "Attempt $attempt", color = Slime.TextMuted, modifier = Modifier.padding(top = 8.dp),
                style = TextStyle(fontFamily = Slime.Mono, fontSize = 12.5.sp)
            )
            if (!stage.isNullOrEmpty()) {
                Muted(stage, Modifier.padding(top = 6.dp), size = 12.5.sp, align = TextAlign.Center)
            }
            Spacer(Modifier.height(12.dp))
            TertiaryButton("Back to Brain list", onBack, color = Slime.Mint)
        }
    }
}

/** renderError. */
@Composable
fun ErrorScreen(
    title: String,
    body: String?,
    detail: String?,
    onTryAgain: (() -> Unit)?,
    onReenterPassword: (() -> Unit)?,
    backLabel: String,
    onBack: () -> Unit
) {
    SlimeScreen {
        ErrorCard(title, body, detail) {
            if (onTryAgain != null) PrimaryButton("Try again", onTryAgain, Modifier.fillMaxWidth())
            if (onReenterPassword != null) SecondaryButton("Re-enter password", onReenterPassword, Modifier.fillMaxWidth())
            TertiaryButton(backLabel, onBack)
        }
    }
}

// ---------------------------------------------------------------- PIN

/** First run: choose a PIN, then type it again. */
@Composable
fun PinSetupScreen(working: Boolean, onChosen: (String) -> Unit, onCancel: (() -> Unit)? = null) {
    var first by remember { mutableStateOf<String?>(null) }
    var entry by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    PinLayout(
        title = if (first == null) "Choose a PIN" else "Type it again",
        subtitle = if (first == null) {
            "It opens Slime OS on this tablet and keeps your Brain’s password safe. " +
                "If you forget it, you can reset the app and pair it again."
        } else {
            "To make sure it’s the one you meant."
        },
        entry = entry,
        error = error,
        enabled = !working,
        onDigit = { d ->
            if (entry.length >= AppLock.PIN_LENGTH) return@PinLayout
            entry += d
            error = null
            if (entry.length == AppLock.PIN_LENGTH) {
                val f = first
                if (f == null) {
                    first = entry
                    entry = ""
                } else if (f == entry) {
                    onChosen(entry)
                } else {
                    first = null
                    entry = ""
                    error = "The PINs didn’t match. Choose one again."
                }
            }
        },
        onDelete = { entry = entry.dropLast(1) },
        footer = { if (onCancel != null) GhostButton("Cancel", onCancel) }
    )
}

/** The lock screen: type the PIN, or reset the app. */
@Composable
fun PinUnlockScreen(
    working: Boolean,
    error: String?,
    retryAtMs: Long,
    onSubmit: (String) -> Unit,
    onForgot: () -> Unit,
    resetKey: Int
) {
    var entry by remember(resetKey) { mutableStateOf("") }
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(retryAtMs) {
        while (System.currentTimeMillis() < retryAtMs) {
            now = System.currentTimeMillis()
            delay(1_000)
        }
        now = System.currentTimeMillis()
    }
    val waitS = ((retryAtMs - now + 999) / 1000).coerceAtLeast(0)
    PinLayout(
        title = "Enter your PIN",
        subtitle = "Slime OS is locked.",
        entry = entry,
        error = if (waitS > 0) "Too many tries. Try again in ${formatWait(waitS)}." else error,
        enabled = !working && waitS == 0L,
        onDigit = { d ->
            if (entry.length >= AppLock.PIN_LENGTH) return@PinLayout
            entry += d
            if (entry.length == AppLock.PIN_LENGTH) onSubmit(entry)
        },
        onDelete = { entry = entry.dropLast(1) },
        footer = { GhostButton("Forgot PIN?", onForgot) }
    )
}

private fun formatWait(s: Long): String =
    if (s < 60) "$s s" else "${(s + 59) / 60} min"

@Composable
private fun PinLayout(
    title: String,
    subtitle: String,
    entry: String,
    error: String?,
    enabled: Boolean,
    onDigit: (Char) -> Unit,
    onDelete: () -> Unit,
    footer: @Composable () -> Unit
) {
    SlimeScreen {
        SlimeMark(52.dp)
        Spacer(Modifier.height(20.dp))
        ScreenTitle(title, size = 26.sp)
        Muted(subtitle, Modifier.padding(top = 8.dp).widthIn(max = 400.dp), align = TextAlign.Center)
        Row(Modifier.padding(top = 28.dp, bottom = 10.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            repeat(AppLock.PIN_LENGTH) { i ->
                val filled = i < entry.length
                Box(
                    Modifier.size(14.dp).clip(CircleShape)
                        .background(if (filled) Slime.AccentGradient else SolidColor(Slime.Field))
                        .border(1.dp, if (filled) Slime.Teal else Slime.BorderDashed, CircleShape)
                )
            }
        }
        Text(
            error ?: "", color = Slime.Error, textAlign = TextAlign.Center,
            modifier = Modifier.height(22.dp),
            style = TextStyle(fontFamily = Slime.Body, fontSize = 13.sp)
        )
        Spacer(Modifier.height(10.dp))
        PinPad(enabled, onDigit, onDelete)
        Spacer(Modifier.height(14.dp))
        footer()
    }
}

@Composable
private fun PinPad(enabled: Boolean, onDigit: (Char) -> Unit, onDelete: () -> Unit) {
    val rows = listOf("123", "456", "789", " 0<")
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        rows.forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(18.dp)) {
                row.forEach { c ->
                    when (c) {
                        ' ' -> Spacer(Modifier.size(64.dp))
                        '<' -> PadKey("⌫", enabled, small = true, onClick = onDelete)
                        else -> PadKey(c.toString(), enabled) { onDigit(c) }
                    }
                }
            }
        }
    }
}

@Composable
private fun PadKey(label: String, enabled: Boolean, small: Boolean = false, onClick: () -> Unit) {
    Box(
        Modifier.size(64.dp).clip(CircleShape)
            .background(if (small) Slime.Shell.copy(alpha = 0f) else Slime.Surface)
            .border(1.dp, if (small) Slime.Shell.copy(alpha = 0f) else Slime.Border, CircleShape)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        Text(
            label, color = if (enabled) Slime.Text else Slime.TextDim,
            style = TextStyle(fontFamily = Slime.Display, fontWeight = FontWeight.SemiBold, fontSize = if (small) 20.sp else 24.sp)
        )
    }
}

// ---------------------------------------------------------------- Settings

enum class SettingsTab(val group: String, val label: String) {
    Pairing("Network", "Pairing"),
    Video("Display & Sound", "Video"),
    Security("Security & Privacy", "App PIN"),
    About("System", "About")
}

class SettingsInfo(
    val paired: Boolean,
    val tunnel: TunnelUi,
    val brainName: String?,
    val brainHost: String?,
    val h264Supported: Boolean,
    val h264Enabled: Boolean,
    val h264Notice: String,
    val smoothResolution: Boolean,
    val pinSet: Boolean,
    val version: String
)

class SettingsActions(
    val onClose: () -> Unit,
    val onTab: (SettingsTab) -> Unit,
    val onPair: () -> Unit,
    val onForgetPairing: () -> Unit,
    val onH264: (Boolean) -> Unit,
    val onShowLicence: () -> Unit,
    val onSmoothResolution: (Boolean) -> Unit,
    val onChangePin: () -> Unit,
    val onLockNow: () -> Unit
)

/** renderSettingsShell: sidebar of categories, the page on the right. */
@Composable
fun SettingsPanel(tab: SettingsTab, info: SettingsInfo, actions: SettingsActions, compact: Boolean, height: Dp) {
    Column(
        Modifier.padding(if (compact) 12.dp else 24.dp).widthIn(max = 840.dp).fillMaxWidth()
            .height(height)
            .clip(RoundedCornerShape(20.dp)).background(Slime.Surface)
            .border(1.dp, Slime.BorderField, RoundedCornerShape(20.dp))
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null
            ) {}
    ) {
        Row(
            Modifier.fillMaxWidth().padding(start = 26.dp, end = 14.dp, top = 16.dp, bottom = 10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                "Settings", color = Slime.Title, modifier = Modifier.weight(1f),
                style = TextStyle(fontFamily = Slime.Display, fontWeight = FontWeight.Bold, fontSize = 19.sp)
            )
            Box(
                Modifier.size(40.dp).clip(RoundedCornerShape(8.dp))
                    .clickable(role = Role.Button, onClickLabel = "Close", onClick = actions.onClose),
                contentAlignment = Alignment.Center
            ) { Text("×", color = Slime.TextMuted, fontSize = 22.sp) }
        }
        Box(Modifier.fillMaxWidth().height(1.dp).background(Slime.Border))
        if (compact) {
            // Phones: the categories as a row of tabs instead of a sidebar.
            Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp, vertical = 8.dp)) {
                SettingsTab.entries.forEach { t -> SubTab(t.label, t == tab) { actions.onTab(t) } }
            }
            Box(Modifier.fillMaxWidth().height(1.dp).background(Slime.Border))
            SettingsPage(tab, info, actions, Modifier.weight(1f))
        } else {
            Row(Modifier.weight(1f)) {
                Column(Modifier.width(196.dp).padding(horizontal = 12.dp, vertical = 16.dp)) {
                    SettingsTab.entries.forEach { t ->
                        val active = t == tab
                        Text(
                            t.group, color = if (active) Slime.Mint else Slime.TextMuted,
                            modifier = Modifier.fillMaxWidth().padding(bottom = 4.dp)
                                .clip(RoundedCornerShape(8.dp))
                                .background(if (active) Slime.Teal.copy(alpha = 0.10f) else Slime.Shell.copy(alpha = 0f))
                                .clickable(role = Role.Tab) { actions.onTab(t) }
                                .padding(horizontal = 12.dp, vertical = 12.dp),
                            style = TextStyle(fontFamily = Slime.Display, fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
                        )
                    }
                }
                Box(Modifier.width(1.dp).fillMaxHeight().background(Slime.Border))
                Column(Modifier.weight(1f)) {
                    Row(Modifier.padding(start = 16.dp, top = 10.dp)) { SubTab(tab.label, true) {} }
                    Box(Modifier.fillMaxWidth().height(1.dp).background(Slime.Border))
                    SettingsPage(tab, info, actions, Modifier.weight(1f))
                }
            }
        }
    }
}

@Composable
private fun SubTab(label: String, active: Boolean, onClick: () -> Unit) {
    Column(
        Modifier.clip(RoundedCornerShape(6.dp)).clickable(role = Role.Tab, onClick = onClick)
            .padding(horizontal = 12.dp).padding(top = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Text(
            label, color = if (active) Slime.Mint else Slime.TextMuted,
            style = TextStyle(fontFamily = Slime.Display, fontWeight = FontWeight.SemiBold, fontSize = 13.5.sp)
        )
        Spacer(Modifier.height(9.dp))
        Box(Modifier.height(2.dp).width(if (active) 28.dp else 0.dp).background(Slime.Mint))
    }
}

@Composable
private fun SettingsPage(tab: SettingsTab, info: SettingsInfo, actions: SettingsActions, modifier: Modifier) {
    Column(
        modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 26.dp, vertical = 22.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)
    ) {
        when (tab) {
            SettingsTab.Pairing -> {
                PageHeading(
                    "Pairing",
                    "The secure tunnel between this tablet and your Brain. A pairing code from your " +
                        "admin sets it up once."
                )
                if (info.paired) {
                    InfoBox(
                        listOf(
                            "Tunnel" to when (info.tunnel) {
                                TunnelUi.Up -> "Secure tunnel"
                                TunnelUi.Connecting -> "Connecting…"
                                TunnelUi.Down -> "Not connected"
                            },
                            "Brain" to (info.brainName ?: "None yet"),
                            "Address" to (info.brainHost ?: "—")
                        )
                    )
                    Muted(
                        "Forgetting the pairing removes this tablet’s tunnel key and the saved Brain " +
                            "password. You’ll need a new pairing code to connect again.",
                        size = 12.5.sp, color = Slime.TextFaint
                    )
                    Row { DangerButton("Forget pairing", actions.onForgetPairing) }
                } else {
                    Muted("This tablet isn’t paired yet.")
                    Row { PrimaryButton("Pair with a Brain", actions.onPair) }
                }
            }
            SettingsTab.Video -> {
                PageHeading("Video", "How your Brain’s screen is sent to this tablet.")
                if (info.h264Supported) {
                    ToggleRow(
                        "Smooth video (H.264)",
                        "Downloaded from Cisco on first use. ${info.h264Notice}",
                        info.h264Enabled, actions.onH264
                    )
                    Row { TertiaryButton("OpenH264 licence", actions.onShowLicence, color = Slime.Mint) }
                } else {
                    Muted("Smooth video isn’t available on this tablet’s processor.")
                }
            }
            SettingsTab.Security -> {
                PageHeading(
                    "App PIN",
                    "Asked when Slime OS opens and after it’s been in the background for a few minutes."
                )
                if (info.pinSet) {
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        SecondaryButton("Change PIN", actions.onChangePin)
                        SecondaryButton("Lock now", actions.onLockNow)
                    }
                } else {
                    Row { PrimaryButton("Choose a PIN", actions.onChangePin) }
                }
                Muted(
                    "Forgot it? On the lock screen, “Forgot PIN?” resets Slime OS on this tablet. " +
                        "Your Brain and everything on it stay as they are.",
                    size = 12.5.sp, color = Slime.TextFaint
                )
            }
            SettingsTab.About -> {
                PageHeading("About", "Slime OS for Android tablets.")
                InfoBox(listOf("Version" to info.version))
            }
        }
    }
}

@Composable
private fun PageHeading(title: String, blurb: String) {
    Column {
        Text(
            title, color = Slime.Title,
            style = TextStyle(fontFamily = Slime.Display, fontWeight = FontWeight.Bold, fontSize = 21.sp)
        )
        Muted(blurb, Modifier.padding(top = 6.dp))
    }
}
