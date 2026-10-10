package com.slimeos.app

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.os.BatteryManager
import android.telephony.TelephonyManager

/**
 * The bits of Android's status bar the app shows itself, since the Membrane screens hide
 * it: the tablet's own network (Wi-Fi or mobile signal) and battery. Read on the status
 * strip's 5 s tick, so no receivers or callbacks to unregister.
 */
data class DeviceStatus(
    val network: Network,
    /** 0..3 for Wi-Fi, 0..4 for mobile, like the system icons. */
    val signal: Int,
    /** 0..100, or null on a device without a battery. */
    val batteryPercent: Int?,
    val charging: Boolean
) {
    enum class Network { None, Wifi, Cellular, Ethernet }

    companion object {
        fun read(context: Context): DeviceStatus {
            val (network, signal) = readNetwork(context)
            // A sticky broadcast: registering with no receiver just returns the last one.
            val battery = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            var percent: Int? = null
            var charging = false
            if (battery != null && battery.getBooleanExtra(BatteryManager.EXTRA_PRESENT, true)) {
                val level = battery.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
                val scale = battery.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
                if (level >= 0 && scale > 0) percent = (level * 100 / scale).coerceIn(0, 100)
                val status = battery.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
                charging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
                    status == BatteryManager.BATTERY_STATUS_FULL
            }
            return DeviceStatus(network, signal, percent, charging)
        }

        // The app's own WireGuard VPN is the default network while the tunnel is up, so
        // look at the networks under it: Wi-Fi first, then Ethernet, then mobile data.
        @Suppress("DEPRECATION") // allNetworks / connectionInfo: no permission-free successor for a one-off read
        private fun readNetwork(context: Context): Pair<Network, Int> {
            val cm = context.getSystemService(ConnectivityManager::class.java) ?: return Network.None to 0
            val transports = cm.allNetworks.mapNotNull { cm.getNetworkCapabilities(it) }
                .filter {
                    !it.hasTransport(NetworkCapabilities.TRANSPORT_VPN) &&
                        it.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                }
            fun has(t: Int) = transports.any { it.hasTransport(t) }
            return when {
                has(NetworkCapabilities.TRANSPORT_WIFI) -> {
                    val rssi = try {
                        context.applicationContext.getSystemService(WifiManager::class.java)?.connectionInfo?.rssi
                    } catch (e: SecurityException) {
                        null
                    }
                    val level = if (rssi == null || rssi <= -127) 3 else WifiManager.calculateSignalLevel(rssi, 4)
                    Network.Wifi to level.coerceIn(0, 3)
                }
                has(NetworkCapabilities.TRANSPORT_ETHERNET) -> Network.Ethernet to 0
                has(NetworkCapabilities.TRANSPORT_CELLULAR) -> {
                    val level = context.getSystemService(TelephonyManager::class.java)?.signalStrength?.level ?: 4
                    Network.Cellular to level.coerceIn(0, 4)
                }
                else -> Network.None to 0
            }
        }
    }
}
