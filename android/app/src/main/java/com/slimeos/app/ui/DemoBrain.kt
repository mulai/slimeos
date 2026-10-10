package com.slimeos.app.ui

import android.annotation.SuppressLint
import android.graphics.Bitmap
import android.net.Uri
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView

/** The Membrane kiosk's DEMO_BRAIN_URL: the slimeos.com demo desktop. */
const val DEMO_BRAIN_URL = "https://slimeos.com/demo/brain/"

/**
 * Demo Brain: until a Brain is added, the welcome screen offers the slimeos.com demo
 * desktop, full screen like a session, so a new tablet shows what a Brain feels like
 * before anyone buys or sets one up. A web page (no RDP, Brain or hub); Disconnect or
 * Back closes it. Same as the kiosk's openDemoBrain().
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun DemoBrainView(modifier: Modifier = Modifier, onClose: () -> Unit) {
    var loaded by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf(false) }
    BackHandler(onBack = onClose)

    Box(modifier.fillMaxSize().background(Slime.Shell), contentAlignment = Alignment.Center) {
        if (!loaded) {
            Text(
                if (failed) "Couldn’t reach the demo Brain. Check the internet connection."
                else "Connecting to the demo Brain…",
                color = Slime.TextMuted, textAlign = TextAlign.Center,
                style = TextStyle(fontFamily = Slime.Mono, fontSize = 12.5.sp),
                modifier = Modifier.padding(24.dp)
            )
        }
        AndroidView(
            modifier = Modifier.fillMaxSize().alpha(if (loaded) 1f else 0f),
            factory = { context ->
                WebView(context).apply {
                    setBackgroundColor(android.graphics.Color.TRANSPARENT)
                    settings.javaScriptEnabled = true
                    settings.domStorageEnabled = true
                    webViewClient = object : WebViewClient() {
                        override fun onPageStarted(view: WebView, url: String?, favicon: Bitmap?) {
                            failed = false
                        }

                        override fun onPageFinished(view: WebView, url: String?) {
                            if (!failed) loaded = true
                        }

                        override fun onReceivedError(
                            view: WebView, request: WebResourceRequest, error: WebResourceError
                        ) {
                            if (request.isForMainFrame) {
                                failed = true
                                loaded = false
                            }
                        }

                        // Stay on the demo: nothing else of the web opens in here.
                        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest) =
                            request.url.host != Uri.parse(DEMO_BRAIN_URL).host
                    }
                    loadUrl(DEMO_BRAIN_URL)
                }
            },
            onRelease = { it.destroy() }
        )

        // Like a remote-desktop connection bar, as on the Membrane.
        Row(
            Modifier.align(Alignment.TopCenter)
                .clip(RoundedCornerShape(bottomStart = 12.dp, bottomEnd = 12.dp))
                .background(Slime.Shell.copy(alpha = 0.85f))
                .border(1.dp, Slime.Border, RoundedCornerShape(bottomStart = 12.dp, bottomEnd = 12.dp))
                .padding(start = 12.dp, end = 8.dp, top = 5.dp, bottom = 5.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            val mono = TextStyle(fontFamily = Slime.Mono, fontSize = 11.5.sp)
            Box(
                Modifier.size(6.dp).drawBehind {
                    drawCircle(Slime.AuroraGreen.copy(alpha = 0.35f), radius = size.minDimension)
                    drawCircle(Slime.AuroraGreen)
                }
            )
            Spacer(Modifier.width(8.dp))
            Text("Demo Brain", style = mono, color = Slime.TextSoft)
            Spacer(Modifier.width(10.dp))
            Text(
                "Disconnect", style = mono, color = Slime.Text,
                modifier = Modifier.clip(RoundedCornerShape(7.dp))
                    .border(1.dp, Slime.BorderButton, RoundedCornerShape(7.dp))
                    .clickable(role = Role.Button, onClick = onClose)
                    .padding(horizontal = 12.dp, vertical = 6.dp)
            )
        }
    }
}
