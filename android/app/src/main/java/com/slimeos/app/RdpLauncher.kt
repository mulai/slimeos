package com.slimeos.app

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
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
 * defers (sound/mic/cam redirection, drive redirection, scale flags).
 */
object RdpLauncher {

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
            append("&dynamic-resolution=")
            // The connect(Uri) path (unlike connect(BookmarkBase)) skips freeRDPCore's
            // own "match resolution to device" logic entirely, so without explicit w/h
            // it falls back to a small built-in default and letterboxes instead of
            // filling the screen — pass the real window size explicitly instead.
            append("&w=").append(widthPx)
            append("&h=").append(heightPx)
        }
        val uri = Uri.parse("freerdp://$authority/connect?$query")

        val intent = Intent(Intent.ACTION_VIEW, uri)
        intent.component = ComponentName(context, SlimeSessionActivity::class.java)
        intent.putExtra(SlimeSessionActivity.EXTRA_PASSWORD, password)
        return intent
    }

    private val TUNNEL_HOST = Regex("^10\\.1[01]\\.0\\.\\d{1,3}$")
}
