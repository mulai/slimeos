package com.slimeos.app

import android.app.Activity
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.lifecycleScope
import com.wireguard.android.backend.GoBackend
import com.wireguard.android.backend.Tunnel
import com.wireguard.config.Config
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private const val TUNNEL_NAME = "slimeos0"

/**
 * M1 proof-of-concept: pairing code -> WireGuard tunnel -> bare RDP connect.
 * No settings, no Brain picker, no Slime ID, no credential auto-delivery —
 * see .claude/plans/fizzy-wobbling-cosmos.md for what's deliberately deferred.
 */
class MainActivity : ComponentActivity() {

    private lateinit var backend: GoBackend
    private val tunnel = object : Tunnel {
        override fun getName() = TUNNEL_NAME
        override fun onStateChange(newState: Tunnel.State) {
            uiState.status = "Tunnel state: $newState"
        }
    }

    private var pendingConfig: Config? = null
    private val uiState = UiState()

    private val vpnPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
            if (result.resultCode == Activity.RESULT_OK) {
                pendingConfig?.let { bringTunnelUp(it) }
            } else {
                uiState.status = "VPN permission denied — tunnel cannot start."
            }
        }

    private val rdpSessionLauncher =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
            // Best-effort parity with connect.sh's notify_session_ended(): tell
            // brain/power to force-logoff the stale disconnected session so this
            // client doesn't reintroduce the stuck-quarter-frame bug fixed in #17.
            val host = uiState.rdpHost
            lifecycleScope.launch { withContext(Dispatchers.IO) { BrainPower.notifySessionEnded(host) } }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        backend = GoBackend(applicationContext)

        setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    PairingScreen(
                        state = uiState,
                        onPair = { host, code -> doPair(host, code) },
                        onConnect = { host, port, user, pass -> doConnect(host, port, user, pass) }
                    )
                }
            }
        }
    }

    private fun doPair(enrollmentHost: String, code: String) {
        lifecycleScope.launch {
            uiState.status = "Pairing..."
            try {
                val config = withContext(Dispatchers.IO) {
                    PairingApi.fetchWireGuardConfig(enrollmentHost, code)
                }
                pendingConfig = config
                uiState.status = "Requesting VPN permission..."
                val intent = GoBackend.VpnService.prepare(this@MainActivity)
                if (intent != null) {
                    vpnPermissionLauncher.launch(intent)
                } else {
                    bringTunnelUp(config)
                }
            } catch (e: Exception) {
                uiState.status = "Pairing failed: ${e.message}"
            }
        }
    }

    private fun bringTunnelUp(config: Config) {
        lifecycleScope.launch {
            uiState.status = "Bringing up tunnel..."
            try {
                withContext(Dispatchers.IO) {
                    backend.setState(tunnel, Tunnel.State.UP, config)
                }
                uiState.tunnelUp = true
                uiState.status = "Tunnel up."
            } catch (e: Exception) {
                uiState.status = "Tunnel failed: ${e.message}"
            }
        }
    }

    private fun doConnect(host: String, port: Int, username: String, password: String) {
        uiState.rdpHost = host
        lifecycleScope.launch {
            uiState.status = "Waking Brain..."
            val awake = withContext(Dispatchers.IO) { waitForBrainAwake(host) }
            if (!awake) {
                uiState.status = "Brain didn't wake in time — try again."
                return@launch
            }
            uiState.status = "Connecting..."
            val bounds = windowManager.currentWindowMetrics.bounds
            rdpSessionLauncher.launch(
                RdpLauncher.buildSessionIntent(
                    this@MainActivity, host, port, username, password,
                    widthPx = bounds.width(), heightPx = bounds.height()
                )
            )
        }
    }

    // Mirrors connect.sh's wake_brain(): some Brains (e.g. Azure) auto-deallocate when
    // idle, so /wake must be called and polled until running before RDP can connect —
    // otherwise the TCP attempt just times out against a powered-off VM.
    private suspend fun waitForBrainAwake(host: String): Boolean {
        val deadlineMs = System.currentTimeMillis() + 3 * 60_000L
        var attempt = 0
        while (System.currentTimeMillis() < deadlineMs) {
            attempt++
            when (BrainPower.wake(host)) {
                BrainPower.WakeState.Ready -> return true
                BrainPower.WakeState.Failed -> return false
                BrainPower.WakeState.Starting, is BrainPower.WakeState.Error -> {
                    withContext(Dispatchers.Main) { uiState.status = "Waking Brain... (attempt $attempt)" }
                    delay(5_000)
                }
            }
        }
        return false
    }
}

private class UiState {
    var status by mutableStateOf("")
    var tunnelUp by mutableStateOf(false)
    var rdpHost by mutableStateOf("")
}

@Composable
private fun PairingScreen(
    state: UiState,
    onPair: (host: String, code: String) -> Unit,
    onConnect: (host: String, port: Int, user: String, pass: String) -> Unit
) {
    var enrollmentHost by remember { mutableStateOf("enroll.slimeos.com") }
    var code by remember { mutableStateOf("") }
    var rdpHost by remember { mutableStateOf("10.11.0.10") }
    var rdpPort by remember { mutableStateOf("3389") }
    var username by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }

    Column(
        modifier = Modifier.padding(24.dp).fillMaxSize(),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Text("Slime OS — M1 spike", style = MaterialTheme.typography.headlineSmall)

        if (!state.tunnelUp) {
            OutlinedTextField(
                value = enrollmentHost,
                onValueChange = { enrollmentHost = it },
                label = { Text("Enrollment host") }
            )
            OutlinedTextField(
                value = code,
                onValueChange = { code = it },
                label = { Text("Pairing code") }
            )
            Button(onClick = { onPair(enrollmentHost, code) }) { Text("Pair") }
        } else {
            Text("Tunnel up — connect to the Brain:")
            OutlinedTextField(
                value = rdpHost,
                onValueChange = { rdpHost = it },
                label = { Text("Brain host (in-tunnel address)") }
            )
            OutlinedTextField(
                value = rdpPort,
                onValueChange = { rdpPort = it },
                label = { Text("Port") }
            )
            OutlinedTextField(
                value = username,
                onValueChange = { username = it },
                label = { Text("Username") }
            )
            OutlinedTextField(
                value = password,
                onValueChange = { password = it },
                label = { Text("Password") }
            )
            Button(onClick = {
                onConnect(rdpHost, rdpPort.toIntOrNull() ?: 3389, username, password)
            }) { Text("Connect") }
        }

        Text(state.status)
    }
}
