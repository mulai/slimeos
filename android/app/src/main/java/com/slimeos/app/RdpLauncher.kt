package com.slimeos.app

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import java.net.URLEncoder
import java.nio.charset.StandardCharsets

/**
 * M1 spike: builds a `freerdp://` URI for freeRDPCore's SessionActivity
 * (com.freerdp.freerdpcore.presentation.SessionActivity, exported, ACTION_VIEW).
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
        password: String
    ): Intent {
        val authority = "${enc(username)}@$host:$port"
        val query = buildString {
            append("sec=").append(enc("rdp:off"))
            append("&cert=ignore")
            append("&network=auto")
            append("&dynamic-resolution=")
            append("&f=")
            append("&p=").append(enc(password))
        }
        val uri = Uri.parse("freerdp://$authority/connect?$query")

        // SessionActivity lives in the freeRDPCore *library* module, so its manifest
        // merges into our own app package (com.slimeos.app) at build time — the class
        // name stays fully-qualified as com.freerdp.freerdpcore..., but the component's
        // package must be our app's actual package, not freeRDPCore's namespace.
        val intent = Intent(Intent.ACTION_VIEW, uri)
        intent.component = ComponentName(
            context.packageName,
            "com.freerdp.freerdpcore.presentation.SessionActivity"
        )
        return intent
    }
}
