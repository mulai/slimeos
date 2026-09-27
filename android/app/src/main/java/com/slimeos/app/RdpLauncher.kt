package com.slimeos.app

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.system.Os
import java.net.URLEncoder
import java.nio.charset.StandardCharsets

/**
 * M1 spike: builds a `freerdp://` URI for freeRDPCore's SessionActivity, via
 * our SlimeSessionActivity subclass (not exported, #47). The password goes as
 * an extra, not in the URI; SlimeSessionActivity adds it in-process.
 *
 * freeRDPCore's LibFreeRDP.setConnectionInfo(Uri) maps each query param directly
 * onto an xfreerdp-style flag (key=value -> /key:value, key= -> /key), so this
 * mirrors the exact flags membrane/freerdp/connect.sh passes to xfreerdp3 for the
 * desktop Membrane (see connect.sh:731-745), skipping only what M1 explicitly
 * defers (mic/cam redirection, drive redirection, scale flags).
 */
object RdpLauncher {

    private const val AUTO_RECONNECT_TRIES = 6

    private fun enc(value: String): String =
        URLEncoder.encode(value, StandardCharsets.UTF_8.name())

    fun buildSessionIntent(
        context: Context,
        host: String,
        port: Int,
        username: String,
        password: String,
        widthPx: Int,
        heightPx: Int
    ): Intent {
        val authority = "${enc(username)}@$host:$port"
        val query = buildString {
            append("sec=").append(enc("rdp:off"))
            // Same rule as connect.sh's cert_flag: over the WireGuard tunnel
            // the hub already proves which Brain answers; any other host
            // gets freeRDPCore's own "verify certificate" dialog.
            if (TUNNEL_HOST.matches(host)) append("&cert=ignore")
            append("&network=auto")
            // Tell Windows not to wait for frame acknowledgements. Otherwise it sends
            // the next frame only once earlier ones are acked, so the frame rate is
            // capped by round trip + decode time (~70 ms here: ~20 fps, audio
            // following). The tablet decodes a frame in ~25 ms, well under 30 fps.
            append("&gfx=").append(enc("frame-ack:off"))
            // Play the Brain's audio here (OpenSL ES) instead of FreeRDP's fake backend.
            append("&sound=")
            // Video optimised remoting (MS-RDPEVOR), as connect.sh's +video: Windows sends
            // playing video as its own stream, presented on its own timeline.
            append("&video=")
            append("&dynamic-resolution=")
            // Reconnect inside the session on a drop (e.g. the Brain's TermService
            // crashing and restarting): the desktop stays on screen and Windows hands
            // back the same session. First try at once, then every 5 s; FreeRDP never
            // retries on a credentials error. If all fail, MainActivity takes over.
            append("&auto-reconnect=+")
            append("&auto-reconnect-max-retries=").append(AUTO_RECONNECT_TRIES)
            // The connect(Uri) path (unlike connect(BookmarkBase)) skips freeRDPCore's
            // own "match resolution to device" logic entirely, so without explicit w/h
            // it falls back to a small built-in default and letterboxes instead of
            // filling the screen — pass the real window size explicitly instead.
            append("&w=").append(widthPx)
            append("&h=").append(heightPx)
        }
        val uri = Uri.parse("freerdp://$authority/connect?$query")

        // Slime OS UDP transport (freerdp-patches/udp-transport.patch), the same
        // switches connect.sh sets for "Faster (beta)": graphics, cursor, video and
        // audio ride RDP-UDP2, and FreeRDP falls back to TCP if UDP goes quiet.
        Os.setenv("SLIMEOS_UDP_NATIVE", "1", true)
        Os.setenv("SLIMEOS_UDP_SEND", "1", true)

        // freeRDPCore's own immersive mode: Android's status and navigation bars
        // hide during the session (swipe from an edge to bring them back), so the
        // view is the whole screen, the size the session is requested at above.
        // Otherwise the desktop is 42 px taller than the view and the Windows
        // taskbar at the bottom sits off screen until you scroll.
        context.getSharedPreferences(context.packageName + "_preferences", Context.MODE_PRIVATE)
            .edit()
            .putBoolean("ui.hide_status_bar", true)
            .putBoolean("ui.hide_navigation_bar", true)
            .apply()

        val intent = Intent(Intent.ACTION_VIEW, uri)
        intent.component = ComponentName(context, SlimeSessionActivity::class.java)
        intent.putExtra(SlimeSessionActivity.EXTRA_PASSWORD, password)
        return intent
    }

    private val TUNNEL_HOST = Regex("^10\\.1[01]\\.0\\.\\d{1,3}$")
}
