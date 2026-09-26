package com.slimeos.app

import android.os.Bundle
import com.freerdp.freerdpcore.presentation.SessionActivity

/**
 * freeRDPCore's SessionActivity only takes connection settings from its
 * `freerdp://` URI, password included. RdpLauncher sends the password as an
 * extra instead, and it is added to the URI here, inside this process, just
 * before SessionActivity reads it (#47): the intent the system routes, logs
 * and keeps for recents never holds it. If Android ever recreates this
 * activity from its own copy of the intent, freeRDPCore asks for the password.
 */
class SlimeSessionActivity : SessionActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        val password = intent.getStringExtra(EXTRA_PASSWORD)
        val uri = intent.data
        if (password != null && uri != null) {
            intent.data = uri.buildUpon().appendQueryParameter("p", password).build()
            intent.removeExtra(EXTRA_PASSWORD)
        }
        super.onCreate(savedInstanceState)
    }

    companion object {
        const val EXTRA_PASSWORD = "com.slimeos.app.extra.PASSWORD"
    }
}
