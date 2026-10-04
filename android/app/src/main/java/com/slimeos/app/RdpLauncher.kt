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
            // Frame acknowledgements stay on (no gfx frame-ack:off): Windows then sends
            // only as fast as the tablet decodes. Without them the Azure Brain's NVIDIA
            // encoder sent 32 frames/s to a MatePad SE 11 decoding ~24 (2026-10-04):
            // H.264 frames can't be skipped, so the rest queued in the app (+0.6 MB/s)
            // and video and sound fell further behind the longer they played. With
            // acks: 19-25 frames/s from the Brain, memory flat, no growing lag.
            // No gfx codec option: FreeRDP's default offers AVC444, and it is the faster
            // one here. Forcing AVC420 (2026-10-04, Smooth, full-screen YouTube) dropped
            // the MatePad from 27-31 to 19-23 frames/s with the decoding thread at 77 %:
            // AVC444's colour conversion runs on 8 worker threads, AVC420's mostly doesn't.
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
            // "+" must be encoded: a raw one decodes to a space, and one bad flag
            // fails the whole argument list ("Missing hostname").
            append("&auto-reconnect=").append(enc("+"))
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
