package com.slimeos.app

import android.app.Activity
import android.content.Intent
import android.graphics.Point
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.displayCutout
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBars
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.min
import androidx.compose.ui.unit.sp
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import com.freerdp.freerdpcore.presentation.SessionActivity
import com.slimeos.app.ui.AddBrainScreen
import com.slimeos.app.ui.ConnectingScreen
import com.slimeos.app.ui.CredentialsScreen
import com.slimeos.app.ui.DangerButton
import com.slimeos.app.ui.ErrorScreen
import com.slimeos.app.ui.FeedbackStatus
import com.slimeos.app.ui.ModalTitle
import com.slimeos.app.ui.Muted
import com.slimeos.app.ui.PairScreen
import com.slimeos.app.ui.PickerScreen
import com.slimeos.app.ui.PinSetupScreen
import com.slimeos.app.ui.PinUnlockScreen
import com.slimeos.app.ui.ReconnectingScreen
import com.slimeos.app.ui.SecondaryButton
import com.slimeos.app.ui.SettingsActions
import com.slimeos.app.ui.SettingsInfo
import com.slimeos.app.ui.SettingsPanel
import com.slimeos.app.ui.SettingsTab
import com.slimeos.app.ui.Slime
import com.slimeos.app.ui.SlimeBackground
import com.slimeos.app.ui.SlimeModal
import com.slimeos.app.ui.SlimeTheme
import com.slimeos.app.ui.StatusStrip
import com.slimeos.app.ui.DemoBrainView
import com.slimeos.app.ui.TunnelUi
import com.slimeos.app.ui.WelcomeScreen
import com.slimeos.app.ui.WorkingScreen
import com.wireguard.android.backend.GoBackend
import com.wireguard.android.backend.Tunnel
import com.wireguard.config.Config
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private const val TUNNEL_NAME = "slimeos0"

// A session that got connected (so the password worked) and then died with no
// reason from the server was a network drop or a TermService crash. Windows keeps
// the session waiting, so reconnect into it. Sessions shorter than MIN_SESSION_MS
// get MAX_QUICK_RECONNECTS tries in a row, so a Brain that fails on every connect
// doesn't loop forever.
private const val MIN_SESSION_MS = 60_000L
private const val MAX_QUICK_RECONNECTS = 3
private const val RECONNECT_DELAY_MS = 5_000L

// The server's ERRINFO_* codes for a session the user ended on purpose (FreeRDP
// error.h): logoff, or disconnect/logoff from Windows' own menu. Only these (or a
// disconnect from this app) let the hub log the session off. Not 1
// (RPC_INITIATED_DISCONNECT): Windows sends it for a shutdown but also when
// TermService restarts, and logging off then would throw the session away.
private val CLEAN_END_ERRINFO = setOf(2, 11, 12)
private const val ERRINFO_DISCONNECTED_BY_OTHERCONNECTION = 5

// Back in the app after this long elsewhere asks for the PIN again. Time in our
// own RDP session doesn't count: Windows has its own lock.
private const val LOCK_AFTER_BACKGROUND_MS = 5 * 60_000L
private const val STATE_LOCKED = "locked"

/**
 * Pairing code -> WireGuard tunnel -> RDP session, with the Membrane kiosk's
 * screens (membrane/lockscreen/index.html): welcome, pair, add a Brain, who
 * signs in, choose a Brain, connecting, error, reconnecting, and Settings.
 * One Brain per tablet for now; no Slime ID yet.
 */
class MainActivity : ComponentActivity() {

    private lateinit var backend: GoBackend
    private lateinit var saved: SavedPairing
    private lateinit var appLock: AppLock
    private val tunnel = object : Tunnel {
        override fun getName() = TUNNEL_NAME
        override fun onStateChange(newState: Tunnel.State) {
            runOnUiThread {
                ui.tunnel = if (newState == Tunnel.State.UP) TunnelUi.Up else TunnelUi.Down
            }
        }
    }

    private var pendingConfig: Config? = null
    private var tunnelStarting = false
    // Why the tunnel is coming up: a new pairing, or a tap on a Brain.
    private var tunnelForPairing = false
    private var connectAfterTunnel = false
    private val ui = UiState()

    private val vpnPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
            if (result.resultCode == Activity.RESULT_OK) {
                pendingConfig?.let { bringTunnelUp(it) }
            } else {
                tunnelStarting = false
                tunnelFailed(
                    "Slime OS needs the VPN permission.",
                    "It opens a private tunnel to your Brain only; nothing else goes through it.",
                    "VPN permission denied"
                )
            }
        }

    private var lastConnect: SavedPairing.Brain? = null
    private var sessionStartedAt = 0L
    private var reconnecting = false
    private var quickReconnects = 0
    private var connectJob: Job? = null
    private var statusJob: Job? = null
    private var sessionRunning = false
    private var backgroundedAt = 0L

    private val rdpSessionLauncher =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
            onSessionEnded(result.resultCode, result.data)
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        installSplashScreen()
        super.onCreate(savedInstanceState)
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT)
        )
        Reporter.install(applicationContext)
        lifecycleScope.launch(Dispatchers.IO) { Reporter.sendPending(applicationContext) }
        backend = GoBackend(applicationContext)
        saved = SavedPairing(applicationContext)
        appLock = AppLock(applicationContext)
        ui.savedBrain = saved.brain
        ui.h264Enabled = OpenH264.isEnabled(applicationContext)
        ui.smoothResolution = DisplayPrefs.resolution(applicationContext) == DisplayPrefs.Resolution.Smooth
        ui.crashReports = Reporter.crashReportsEnabled(applicationContext)
        ui.pinSet = appLock.isSet
        ui.locked = ui.pinSet && (savedInstanceState?.getBoolean(STATE_LOCKED, true) ?: true)
        ui.pinRetryAt = appLock.retryAtMs
        ui.screen = homeScreen()

        // The status strip's tunnel quality and the tablet's own network and battery,
        // while the app is on screen.
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                while (true) {
                    ui.device = DeviceStatus.read(applicationContext)
                    if (ui.tunnel == TunnelUi.Up) {
                        val ms = withContext(Dispatchers.IO) { BrainPower.pingHubMs() }
                        ui.pingMs = ms
                        ui.pingFailed = ms == null
                    } else {
                        ui.pingMs = null
                        ui.pingFailed = false
                    }
                    delay(5_000)
                }
            }
        }

        setContent { SlimeTheme { App() } }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putBoolean(STATE_LOCKED, ui.locked)
    }

    override fun onStart() {
        super.onStart()
        if (backgroundedAt != 0L && ui.pinSet &&
            SystemClock.elapsedRealtime() - backgroundedAt >= LOCK_AFTER_BACKGROUND_MS
        ) {
            lock()
        }
        backgroundedAt = 0L
        if (ui.screen == Screen.Picker) refreshBrainStatus()
    }

    override fun onStop() {
        if (!sessionRunning) backgroundedAt = SystemClock.elapsedRealtime()
        super.onStop()
    }

    override fun onResume() {
        super.onResume()
        hideStatusBar()
        // Paired before: bring the saved tunnel back up instead of asking for a new
        // code. Here rather than in onCreate: Android refuses to start the VPN
        // service while the app is in the background (e.g. launched with the screen
        // off), and onResume is also a retry after such a failure.
        if (ui.tunnel == TunnelUi.Up || tunnelStarting) return
        saved.wgConfig?.let { text ->
            try {
                startTunnel(Config.parse(text.byteInputStream()))
            } catch (e: Exception) {
                saved.wgConfig = null
                ui.screen = Screen.Pair(hint = "The saved pairing couldn’t be read. Pair this tablet again.")
            }
        }
    }

    // ------------------------------------------------------------------ UI

    /**
     * The Membrane screens draw their own status strip (tunnel, network, battery,
     * clock), so Android's status bar stays hidden; a swipe from the top shows it for a
     * moment. The navigation bar stays for Back and Home. The session screen hides both
     * on its own (RdpLauncher).
     */
    private fun hideStatusBar() {
        WindowCompat.getInsetsController(window, window.decorView).apply {
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            hide(WindowInsetsCompat.Type.statusBars())
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideStatusBar()
    }

    @Composable
    private fun App() {
        // Sides and bottom only: the status bar is hidden and the strip is the top edge.
        // Some devices (the MatePad) still report its height as a top inset once hidden,
        // which left an empty band above the strip. The app is landscape-only, so a
        // camera cutout is always on a side.
        val screenInsets = WindowInsets.systemBars.union(WindowInsets.displayCutout)
            .only(WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom)
        SlimeBackground {
            BoxWithConstraints(Modifier.fillMaxSize()) {
                val compact = maxWidth < 600.dp
                val fullHeight = maxHeight
                Column(Modifier.fillMaxSize().windowInsetsPadding(screenInsets)) {
                    val settingsAllowed = !ui.locked && ui.pinSet && !ui.changingPin &&
                        ui.screen !is Screen.Working
                    StatusStrip(
                        ui.tunnel, ui.pingMs, ui.pingFailed, ui.device,
                        onSettings = if (settingsAllowed) ({ ui.settingsTab = SettingsTab.Pairing }) else null
                    )
                    BoxWithConstraints(Modifier.fillMaxWidth().weight(1f).imePadding()) {
                        val viewport = maxHeight
                        Column(
                            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).heightIn(min = viewport),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.Center
                        ) {
                            Content()
                        }
                    }
                }
                ui.settingsTab?.let { tab ->
                    // imePadding: the panel shrinks to the space above the keyboard (half a
                    // landscape tablet), and its page scrolls the field being typed in into view.
                    BoxWithConstraints(
                        Modifier.fillMaxSize().background(Color(0x99040608)).windowInsetsPadding(screenInsets).imePadding()
                            .clickable(
                                interactionSource = remember { MutableInteractionSource() }, indication = null
                            ) { ui.settingsTab = null },
                        contentAlignment = Alignment.Center
                    ) {
                        val keyboardUp = maxHeight < fullHeight * 0.75f
                        val panelHeight = if (keyboardUp) maxHeight - 8.dp else min(600.dp, maxHeight * 0.92f)
                        SettingsPanel(tab, settingsInfo(), settingsActions(), compact, panelHeight, tight = keyboardUp)
                    }
                }
                Modal()
                if (ui.demoBrain) {
                    DemoBrainView(Modifier.windowInsetsPadding(screenInsets), onClose = { ui.demoBrain = false })
                }
            }
        }
    }

    @Composable
    private fun Content() {
        if (!ui.pinSet || ui.changingPin) {
            PinSetupScreen(
                working = ui.pinWorking,
                onChosen = { pin -> choosePin(pin) },
                onCancel = if (ui.changingPin) ({ ui.changingPin = false }) else null
            )
            return
        }
        if (ui.locked) {
            PinUnlockScreen(
                working = ui.pinWorking,
                error = ui.pinError,
                retryAtMs = ui.pinRetryAt,
                onSubmit = { pin -> unlock(pin) },
                onForgot = { ui.modal = Modal.ResetApp },
                resetKey = ui.pinResetKey
            )
            return
        }
        val brain = ui.savedBrain
        when (val s = ui.screen) {
            Screen.Welcome -> WelcomeScreen(
                onAddBrain = { ui.screen = if (saved.wgConfig == null) Screen.Pair() else Screen.AddBrain() },
                onTryDemo = { ui.demoBrain = true }
            )
            is Screen.Pair -> PairScreen(
                hint = s.hint,
                onPair = { host, code -> doPair(host, code) },
                onBack = { showHome() }
            )
            is Screen.Working -> WorkingScreen(s.title, ui.stage)
            is Screen.PairError -> ErrorScreen(
                title = s.title, body = null, detail = s.detail,
                onTryAgain = { ui.screen = Screen.Pair() }, onReenterPassword = null,
                backLabel = "Back", onBack = { showHome() }
            )
            is Screen.AddBrain -> AddBrainScreen(
                initialName = s.name, initialHost = s.host, initialPort = s.port,
                onContinue = { name, host, port -> ui.screen = Screen.Credentials(name, host, port, "") },
                onCancel = { showHome() }
            )
            is Screen.Credentials -> CredentialsScreen(
                brainName = s.name,
                initialUsername = s.username,
                onConnect = { user, pass ->
                    connectTo(SavedPairing.Brain(s.host, s.port, user, pass, s.name))
                },
                onBack = { ui.screen = Screen.AddBrain(s.name, s.host, s.port) }
            )
            Screen.Picker -> if (brain == null) {
                WelcomeScreen(onAddBrain = { ui.screen = Screen.AddBrain() }, onTryDemo = { ui.demoBrain = true })
            } else {
                PickerScreen(
                    name = brain.name, host = brain.host, status = ui.brainStatus, notice = ui.notice,
                    onConnect = { connectTo(brain) },
                    onRemove = { ui.modal = Modal.RemoveBrain }
                )
            }
            Screen.Connecting -> ConnectingScreen(
                brainName = (lastConnect ?: brain)?.name ?: "your Brain",
                stage = ui.stage,
                onCancel = { cancelConnect() }
            )
            Screen.Reconnecting -> ReconnectingScreen(
                attempt = ui.reconnectAttempt, stage = ui.stage.takeIf { it.isNotEmpty() },
                onBack = { cancelConnect() }
            )
            is Screen.Error -> ErrorScreen(
                title = s.title, body = s.body, detail = s.detail,
                onTryAgain = if (s.retry) ({ (lastConnect ?: saved.brain)?.let { connectTo(it) } }) else null,
                onReenterPassword = if (s.reenter) ({
                    (lastConnect ?: saved.brain)?.let {
                        ui.screen = Screen.Credentials(it.name, it.host, it.port, it.username)
                    }
                }) else null,
                backLabel = if (saved.brain != null) "Back to Brain list" else "Back",
                onBack = { showHome() }
            )
        }
    }

    @Composable
    private fun Modal() {
        when (ui.modal) {
            null -> {}
            Modal.RemoveBrain -> SlimeModal(onDismiss = { ui.modal = null }) {
                ModalTitle("Remove ${ui.savedBrain?.name ?: "this Brain"}?")
                Muted(
                    "Its saved password will be deleted too. You’ll need to sign in again next time. " +
                        "This tablet stays paired.",
                    size = 13.sp
                )
                ModalButtons("Remove", onCancel = { ui.modal = null }) {
                    ui.modal = null
                    saved.brain = null
                    ui.savedBrain = null
                    ui.brainStatus = null
                    showHome()
                }
            }
            Modal.ForgetPairing -> SlimeModal(onDismiss = { ui.modal = null }) {
                ModalTitle("Forget this pairing?")
                Muted(
                    "This tablet disconnects from your hub, and its saved Brain password is deleted. " +
                        "You’ll need a new pairing code to connect again.",
                    size = 13.sp
                )
                ModalButtons("Forget", onCancel = { ui.modal = null }) {
                    ui.modal = null
                    ui.settingsTab = null
                    forgetPairing()
                }
            }
            Modal.ResetApp -> SlimeModal(onDismiss = { ui.modal = null }) {
                ModalTitle("Reset Slime OS on this tablet?")
                Muted(
                    "This removes the PIN, the pairing and the saved Brain password from this tablet. " +
                        "Your Brain and everything on it stay as they are. You’ll need a new pairing " +
                        "code to connect again.",
                    size = 13.sp
                )
                ModalButtons("Reset", onCancel = { ui.modal = null }) {
                    ui.modal = null
                    resetApp()
                }
            }
            Modal.Licence -> SlimeModal(onDismiss = { ui.modal = null }) {
                ModalTitle("OpenH264 licence")
                val text = remember { OpenH264.licenseText(applicationContext) }
                Text(
                    text, color = Slime.TextMuted,
                    modifier = Modifier.heightIn(max = 340.dp).verticalScroll(rememberScrollState()),
                    style = TextStyle(fontFamily = Slime.Mono, fontSize = 11.sp, lineHeight = 16.sp)
                )
                Row(Modifier.fillMaxWidth().padding(top = 18.dp)) {
                    SecondaryButton("Close", { ui.modal = null }, Modifier.weight(1f))
                }
            }
        }
    }

    @Composable
    private fun ModalButtons(confirm: String, onCancel: () -> Unit, onConfirm: () -> Unit) {
        Row(Modifier.fillMaxWidth().padding(top = 22.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            SecondaryButton("Cancel", onCancel, Modifier.weight(1f))
            DangerButton(confirm, onConfirm, Modifier.weight(1f))
        }
    }

    private fun settingsInfo() = SettingsInfo(
        paired = saved.wgConfig != null,
        tunnel = ui.tunnel,
        brainName = ui.savedBrain?.name,
        brainHost = ui.savedBrain?.host,
        h264Supported = OpenH264.isSupported,
        h264Enabled = ui.h264Enabled,
        h264Notice = OpenH264.NOTICE,
        smoothResolution = ui.smoothResolution,
        pinSet = ui.pinSet,
        version = try {
            packageManager.getPackageInfo(packageName, 0).versionName ?: "?"
        } catch (e: Exception) {
            "?"
        },
        crashReports = ui.crashReports,
        feedbackCategory = ui.feedbackCategory,
        feedbackMessage = ui.feedbackMessage,
        feedbackStatus = ui.feedbackStatus,
        feedbackResult = ui.feedbackResult
    )

    private fun settingsActions() = SettingsActions(
        onClose = { ui.settingsTab = null },
        onTab = { ui.settingsTab = it },
        onPair = {
            ui.settingsTab = null
            ui.screen = Screen.Pair()
        },
        onForgetPairing = { ui.modal = Modal.ForgetPairing },
        onH264 = { enabled ->
            OpenH264.setEnabled(applicationContext, enabled)
            ui.h264Enabled = enabled
        },
        onShowLicence = { ui.modal = Modal.Licence },
        onSmoothResolution = { smooth ->
            DisplayPrefs.setResolution(
                applicationContext,
                if (smooth) DisplayPrefs.Resolution.Smooth else DisplayPrefs.Resolution.Sharp
            )
            ui.smoothResolution = smooth
        },
        onChangePin = {
            ui.settingsTab = null
            ui.changingPin = true
        },
        onLockNow = {
            ui.settingsTab = null
            lock()
        },
        onCrashReports = { enabled ->
            Reporter.setCrashReportsEnabled(applicationContext, enabled)
            ui.crashReports = enabled
        },
        onFeedbackCategory = {
            ui.feedbackCategory = it
            if (ui.feedbackStatus != FeedbackStatus.Sending) ui.feedbackStatus = FeedbackStatus.Idle
        },
        onFeedbackMessage = {
            ui.feedbackMessage = it
            if (ui.feedbackStatus != FeedbackStatus.Sending) ui.feedbackStatus = FeedbackStatus.Idle
        },
        onSendFeedback = { sendFeedback() }
    )

    private fun sendFeedback() {
        val message = ui.feedbackMessage.trim()
        if (message.length < 3 || ui.feedbackStatus == FeedbackStatus.Sending) return
        val category = listOf("bug", "feature", "other")[ui.feedbackCategory]
        // What the Membrane's feedback_collect_diagnostics() would say, minus anything
        // identifying: no Brain address or name, no pairing details.
        val extra = mapOf<String, Any?>(
            "tunnel" to ui.tunnel.name.lowercase(),
            "paired" to (saved.wgConfig != null),
            "brain_saved" to (ui.savedBrain != null),
            "brain_status" to ui.brainStatus?.name?.lowercase(),
            "pin_set" to ui.pinSet,
            "crash_reports" to ui.crashReports
        )
        ui.feedbackStatus = FeedbackStatus.Sending
        lifecycleScope.launch {
            val result = withContext(Dispatchers.IO) {
                Reporter.sendFeedback(applicationContext, category, message, extra)
            }
            when (result) {
                is Reporter.Result.Sent -> {
                    ui.feedbackStatus = FeedbackStatus.Sent
                    ui.feedbackResult = "Thanks! The Slime OS team has it."
                    ui.feedbackMessage = ""
                }
                is Reporter.Result.Failed -> {
                    ui.feedbackStatus = FeedbackStatus.Error
                    ui.feedbackResult = result.message
                }
            }
        }
    }

    // ------------------------------------------------------------------ PIN

    private fun lock() {
        ui.locked = true
        ui.demoBrain = false
        ui.settingsTab = null
        ui.modal = null
        ui.pinError = null
        ui.pinRetryAt = appLock.retryAtMs
        ui.pinResetKey++
    }

    private fun choosePin(pin: String) {
        ui.pinWorking = true
        lifecycleScope.launch {
            withContext(Dispatchers.Default) { appLock.set(pin) }
            ui.pinWorking = false
            ui.pinSet = true
            ui.changingPin = false
            ui.locked = false
        }
    }

    private fun unlock(pin: String) {
        ui.pinWorking = true
        lifecycleScope.launch {
            val result = withContext(Dispatchers.Default) { appLock.check(pin) }
            ui.pinWorking = false
            ui.pinResetKey++
            when (result) {
                AppLock.Check.Ok -> {
                    ui.locked = false
                    ui.pinError = null
                    ui.pinRetryAt = 0
                }
                is AppLock.Check.Wrong -> ui.pinError = if (result.triesBeforeWait <= 2) {
                    "Wrong PIN. ${result.triesBeforeWait} more " +
                        (if (result.triesBeforeWait == 1) "try" else "tries") + " before a wait."
                } else {
                    "Wrong PIN."
                }
                is AppLock.Check.Wait -> {
                    ui.pinError = null
                    ui.pinRetryAt = result.untilMs
                }
            }
        }
    }

    /** "Forgot PIN?": back to a fresh install. */
    private fun resetApp() {
        forgetPairing()
        appLock.clear()
        ui.pinSet = false
        ui.locked = false
        ui.pinError = null
        ui.pinRetryAt = 0
    }

    // ------------------------------------------------------------------ navigation

    private fun homeScreen(): Screen = if (saved.brain != null) Screen.Picker else Screen.Welcome

    private fun showHome() {
        ui.screen = homeScreen()
        if (ui.screen == Screen.Picker) refreshBrainStatus()
    }

    private fun setStage(text: String) {
        ui.stage = text
    }

    private fun showError(title: String, body: String?, detail: String?, retry: Boolean = true, reenter: Boolean = false) {
        ui.screen = Screen.Error(title, body, detail, retry, reenter)
    }

    /** The picker's Asleep/Offline badge (coordinator.sh's refresh_brain_status). */
    private fun refreshBrainStatus() {
        val brain = saved.brain ?: return
        if (ui.tunnel != TunnelUi.Up) {
            ui.brainStatus = null
            return
        }
        statusJob?.cancel()
        statusJob = lifecycleScope.launch {
            val status = withContext(Dispatchers.IO) { BrainPower.status(brain.host, brain.port) }
            ui.brainStatus = status
        }
    }

    // ------------------------------------------------------------------ pairing and tunnel

    private fun doPair(enrollmentHost: String, code: String) {
        tunnelForPairing = true
        ui.screen = Screen.Working("Pairing")
        setStage("Fetching your Brain’s configuration…")
        lifecycleScope.launch {
            try {
                val config = withContext(Dispatchers.IO) {
                    PairingApi.fetchWireGuardConfig(enrollmentHost, code)
                }
                // The code is single-use, so keep the config before anything else can fail.
                saved.wgConfig = config.toWgQuickString()
                startTunnel(config)
            } catch (e: Exception) {
                tunnelForPairing = false
                ui.screen = Screen.PairError("Couldn’t pair.", e.message)
            }
        }
    }

    private fun startTunnel(config: Config) {
        tunnelStarting = true
        pendingConfig = config
        ui.tunnel = TunnelUi.Connecting
        if (tunnelForPairing) setStage("Asking for the VPN permission…")
        val intent = GoBackend.VpnService.prepare(this)
        if (intent != null) {
            vpnPermissionLauncher.launch(intent)
        } else {
            bringTunnelUp(config)
        }
    }

    private fun bringTunnelUp(config: Config) {
        lifecycleScope.launch {
            if (tunnelForPairing || connectAfterTunnel) setStage("Opening the secure tunnel…")
            try {
                withContext(Dispatchers.IO) {
                    backend.setState(tunnel, Tunnel.State.UP, config)
                }
                ui.tunnel = TunnelUi.Up
                onTunnelUp()
            } catch (e: Exception) {
                tunnelFailed("Couldn’t open the secure tunnel.", "Check this tablet’s internet connection.", e.message)
            } finally {
                tunnelStarting = false
            }
        }
    }

    private fun onTunnelUp() {
        if (tunnelForPairing) {
            tunnelForPairing = false
            ui.screen = if (saved.brain == null) Screen.AddBrain() else Screen.Picker
        }
        if (connectAfterTunnel) {
            connectAfterTunnel = false
            saved.brain?.let { doConnect(it) }
            return
        }
        if (ui.screen == Screen.Picker) refreshBrainStatus()
    }

    private fun tunnelFailed(title: String, body: String, detail: String?) {
        ui.tunnel = TunnelUi.Down
        when {
            tunnelForPairing -> {
                tunnelForPairing = false
                ui.screen = Screen.PairError(title, listOfNotNull(body, detail).joinToString("\n"))
            }
            connectAfterTunnel -> {
                connectAfterTunnel = false
                showError(title, body, detail)
            }
            else -> ui.notice = "$title Tap your Brain to try again."
        }
    }

    private fun forgetPairing() {
        connectJob?.cancel()
        reconnecting = false
        lifecycleScope.launch {
            withContext(Dispatchers.IO) {
                try {
                    backend.setState(tunnel, Tunnel.State.DOWN, null)
                } catch (e: Exception) {
                    // Already down.
                }
            }
        }
        saved.clear()
        ui.savedBrain = null
        ui.brainStatus = null
        ui.notice = null
        ui.tunnel = TunnelUi.Down
        ui.screen = Screen.Welcome
    }

    // ------------------------------------------------------------------ sessions

    /** A tap on a Brain: brings the tunnel up first if it's down. */
    private fun connectTo(brain: SavedPairing.Brain) {
        ui.notice = null
        reconnecting = false
        quickReconnects = 0
        if (ui.tunnel == TunnelUi.Up) {
            doConnect(brain)
            return
        }
        val config = saved.wgConfig
        if (config == null) {
            ui.screen = Screen.Pair()
            return
        }
        saved.brain = brain
        ui.savedBrain = brain
        lastConnect = brain
        connectAfterTunnel = true
        ui.screen = Screen.Connecting
        setStage("Opening the secure tunnel…")
        if (tunnelStarting) return
        try {
            startTunnel(Config.parse(config.byteInputStream()))
        } catch (e: Exception) {
            connectAfterTunnel = false
            saved.wgConfig = null
            ui.screen = Screen.Pair(hint = "The saved pairing couldn’t be read. Pair this tablet again.")
        }
    }

    private fun cancelConnect() {
        connectJob?.cancel()
        connectJob = null
        reconnecting = false
        quickReconnects = 0
        connectAfterTunnel = false
        showHome()
    }

    private fun onSessionEnded(resultCode: Int, data: Intent?) {
        sessionRunning = false
        Reporter.sessionEnded(applicationContext)
        // This activity may have been recreated while the session ran.
        val target = lastConnect ?: saved.brain
        val host = target?.host ?: ""
        val endedByUser = data?.getBooleanExtra(SessionActivity.RESULT_ENDED_BY_USER, false) ?: false
        val errorInfo = data?.getIntExtra(SessionActivity.RESULT_ERROR_INFO, 0) ?: 0
        val wasConnected = data?.getBooleanExtra(SessionActivity.RESULT_WAS_CONNECTED, false) ?: false
        val lasted = SystemClock.elapsedRealtime() - sessionStartedAt
        if (data?.getBooleanExtra(SlimeSessionActivity.RESULT_RESTARTING, false) == true && target != null) {
            // The user chose to restart a frozen Brain; the hub is on it. /wake says
            // "restarting" until the old Windows is down, so just connect again.
            Log.i("MainActivity", "Brain restart requested after a frozen session")
            reconnecting = true
            quickReconnects = 0
            ui.screen = Screen.Connecting
            setStage("Restarting your Brain… (about 2 minutes)")
            doConnect(target)
            return
        }
        Log.i(
            "MainActivity",
            "Session ended after ${lasted / 1000}s: endedByUser=$endedByUser " +
                "errorInfo=$errorInfo wasConnected=$wasConnected"
        )
        if (lasted >= MIN_SESSION_MS) quickReconnects = 0

        // RESULT_OK: the session was up. Cancelling a connect sets endedByUser too, and
        // must not log off the session a drop left waiting.
        if ((endedByUser && resultCode == Activity.RESULT_OK) || errorInfo in CLEAN_END_ERRINFO) {
            // Parity with connect.sh's notify_session_ended(): only after a clean end
            // does brain/power log off the disconnected session (#17). After a drop
            // that would throw away the user's open windows.
            reconnecting = false
            quickReconnects = 0
            lifecycleScope.launch { withContext(Dispatchers.IO) { BrainPower.notifySessionEnded(host) } }
            showHome()
            return
        }
        if (endedByUser) {
            reconnecting = false
            quickReconnects = 0
            showHome()
            return
        }
        if (errorInfo == ERRINFO_DISCONNECTED_BY_OTHERCONNECTION) {
            // Reconnecting would take it straight back from the other device.
            reconnecting = false
            quickReconnects = 0
            ui.notice = "Your session moved to another device."
            showHome()
            return
        }
        val quick = lasted < MIN_SESSION_MS
        // While reconnecting, the same password just worked, so a failed connect
        // (TermService still restarting) may use the remaining tries too.
        if (errorInfo == 0 && (wasConnected || reconnecting || !quick) && target != null &&
            (!quick || quickReconnects < MAX_QUICK_RECONNECTS)
        ) {
            if (quick) quickReconnects++
            if (!reconnecting) ui.reconnectAttempt = 0
            reconnecting = true
            ui.reconnectAttempt++
            ui.screen = Screen.Reconnecting
            setStage("")
            connectJob = lifecycleScope.launch {
                delay(RECONNECT_DELAY_MS)
                doConnect(target)
            }
            return
        }
        // A fast failure: no blind retries, repeated failed logons can lock the account.
        val gaveUp = reconnecting
        reconnecting = false
        quickReconnects = 0
        val name = target?.name ?: "your Brain"
        when {
            errorInfo == 1 -> showError(
                "$name closed the connection.",
                "Your session is kept; connect again when ready.",
                "ERRINFO 1 (RPC_INITIATED_DISCONNECT)"
            )
            errorInfo != 0 -> showError(
                "$name ended the session.",
                "Try again, or re-enter the password if it changed.",
                "ERRINFO $errorInfo", reenter = true
            )
            gaveUp -> showError(
                "The connection keeps dropping.",
                "Your session is kept on the Brain; try again in a minute.",
                "Gave up after $MAX_QUICK_RECONNECTS quick reconnects"
            )
            else -> showError(
                "Couldn’t connect.",
                "Couldn’t connect to $name. Try again in a moment, or re-enter the password if it changed.",
                "No reason from the server (errorInfo 0, wasConnected=$wasConnected)", reenter = true
            )
        }
    }

    private fun doConnect(brain: SavedPairing.Brain) {
        saved.brain = brain
        ui.savedBrain = brain
        lastConnect = brain
        val (host, port) = brain.host to brain.port
        if (!reconnecting) ui.screen = Screen.Connecting
        connectJob?.cancel()
        connectJob = lifecycleScope.launch {
            withContext(Dispatchers.IO) {
                OpenH264.prepareSession(applicationContext) {
                    runOnUiThread { setStage("Downloading the video codec from Cisco…") }
                }
            }
            if (!reconnecting) setStage("Waking up your Brain…")
            val awake = withContext(Dispatchers.IO) { waitForBrainAwake(host, port) }
            if (awake == Awake.No) {
                reconnecting = false
                quickReconnects = 0
                showError(
                    "${brain.name} didn’t wake up.",
                    "Try again in a moment.",
                    "The hub couldn’t start it, or it took longer than 8 minutes."
                )
                return@launch
            }
            // Keep the "not allowed to wake" note visible while connecting.
            if (awake == Awake.Yes) setStage("Connecting…")
            sessionStartedAt = SystemClock.elapsedRealtime()
            sessionRunning = true
            Reporter.sessionStarted(applicationContext)
            val size = DisplayPrefs.sessionSize(applicationContext, screenSize())
            Log.i("MainActivity", "Session size ${size.x}x${size.y} (${DisplayPrefs.resolution(applicationContext)})")
            rdpSessionLauncher.launch(
                RdpLauncher.buildSessionIntent(
                    this@MainActivity, host, port, brain.username, brain.password,
                    widthPx = size.x, heightPx = size.y
                )
            )
        }
    }

    private fun screenSize(): Point {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val b = windowManager.currentWindowMetrics.bounds
            return Point(b.width(), b.height())
        }
        return Point().also {
            @Suppress("DEPRECATION")
            windowManager.defaultDisplay.getRealSize(it)
        }
    }

    private enum class Awake { Yes, No, Unknown }

    // Mirrors connect.sh's wake_brain(): some Brains (e.g. Azure) auto-deallocate when
    // idle, so /wake must be called and polled until running before RDP can connect —
    // otherwise the TCP attempt just times out against a powered-off VM. "Running" is
    // not enough: Azure says so before Windows listens, and while Windows shuts down.
    // So keep asking the hub while waiting for the RDP port; a Brain that stops on the
    // way gets started again by the next /wake.
    private suspend fun waitForBrainAwake(host: String, port: Int): Awake {
        // Covers a wake from deallocated and a frozen-Brain restart (up to ~5 min).
        val deadlineMs = System.currentTimeMillis() + 8 * 60_000L
        var attempt = 0
        var sawRunning = false
        while (System.currentTimeMillis() < deadlineMs) {
            when (BrainPower.wake(host)) {
                BrainPower.WakeState.Ready -> {
                    if (BrainPower.rdpListening(host, port)) return Awake.Yes
                    sawRunning = true
                    withContext(Dispatchers.Main) { setStage("Brain is up. Starting the desktop…") }
                    delay(3_000)
                }
                // The Brain may well be awake; only waking is refused, so try anyway
                // and say why if the connection then fails.
                BrainPower.WakeState.NotAllowed -> {
                    withContext(Dispatchers.Main) {
                        setStage(
                            "This tablet isn’t allowed to wake the Brain. Connecting anyway; " +
                                "if it’s asleep, wake it from another device."
                        )
                    }
                    return Awake.Unknown
                }
                BrainPower.WakeState.Failed -> return Awake.No
                BrainPower.WakeState.Restarting -> {
                    withContext(Dispatchers.Main) { setStage("Restarting your Brain… (about 2 minutes)") }
                    delay(5_000)
                }
                BrainPower.WakeState.Cleaning -> {
                    withContext(Dispatchers.Main) { setStage("Finishing your last session…") }
                    delay(5_000)
                }
                BrainPower.WakeState.Starting, is BrainPower.WakeState.Error -> {
                    attempt++
                    withContext(Dispatchers.Main) { setStage("Waking up your Brain… (attempt $attempt)") }
                    delay(5_000)
                }
            }
        }
        // Running all along but never listening: connect anyway and let FreeRDP say why.
        return if (sawRunning) Awake.Yes else Awake.No
    }
}

private sealed interface Screen {
    object Welcome : Screen
    data class Pair(val hint: String? = null) : Screen
    /** Pairing in progress: ring, title, ui.stage. */
    data class Working(val title: String) : Screen
    data class PairError(val title: String, val detail: String?) : Screen
    data class AddBrain(
        val name: String = "",
        val host: String = "",
        val port: Int = 3389
    ) : Screen
    data class Credentials(val name: String, val host: String, val port: Int, val username: String) : Screen
    object Picker : Screen
    object Connecting : Screen
    object Reconnecting : Screen
    data class Error(
        val title: String,
        val body: String?,
        val detail: String?,
        val retry: Boolean,
        val reenter: Boolean
    ) : Screen
}

private enum class Modal { RemoveBrain, ForgetPairing, ResetApp, Licence }

private class UiState {
    var screen by mutableStateOf<Screen>(Screen.Welcome)
    var stage by mutableStateOf("")
    var notice by mutableStateOf<String?>(null)
    var tunnel by mutableStateOf(TunnelUi.Down)
    var pingMs by mutableStateOf<Long?>(null)
    var pingFailed by mutableStateOf(false)
    var device by mutableStateOf<DeviceStatus?>(null)
    var demoBrain by mutableStateOf(false)
    var savedBrain by mutableStateOf<SavedPairing.Brain?>(null)
    var brainStatus by mutableStateOf<BrainPower.Status?>(null)
    var reconnectAttempt by mutableIntStateOf(0)
    var h264Enabled by mutableStateOf(false)
    var smoothResolution by mutableStateOf(true)
    var crashReports by mutableStateOf(false)
    var feedbackCategory by mutableIntStateOf(0)
    var feedbackMessage by mutableStateOf("")
    var feedbackStatus by mutableStateOf(FeedbackStatus.Idle)
    var feedbackResult by mutableStateOf<String?>(null)
    var settingsTab by mutableStateOf<SettingsTab?>(null)
    var modal by mutableStateOf<Modal?>(null)

    var pinSet by mutableStateOf(false)
    var locked by mutableStateOf(false)
    var changingPin by mutableStateOf(false)
    var pinWorking by mutableStateOf(false)
    var pinError by mutableStateOf<String?>(null)
    var pinRetryAt by mutableLongStateOf(0L)
    var pinResetKey by mutableIntStateOf(0)
}
