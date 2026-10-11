package com.slimeos.app

import android.content.Context
import com.freerdp.freerdpcore.services.LibFreeRDP

/**
 * H.264 video through OpenH264, built from source with FreeRDP and shipped in
 * the APK. The H.264 patents are covered by Mulai's Via LA AVC licence, not
 * Cisco's binary licence, so there is no download and no on/off switch. The
 * source's BSD licence (assets/openh264-license.txt) is shown in Settings > Video.
 *
 * FreeRDP loads the library by name at runtime and only offers H.264 to the
 * Brain when it loads, so without it the session falls back to the other codecs.
 */
object OpenH264 {

    private const val LICENSE_ASSET = "openh264-license.txt"

    val isSupported: Boolean
        get() = LibFreeRDP.hasH264Support()

    fun licenseText(context: Context): String =
        context.assets.open(LICENSE_ASSET).bufferedReader().use { it.readText() }
}
