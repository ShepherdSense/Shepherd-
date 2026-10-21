package com.example.rf_sentry

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.wifi.WifiManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import android.net.wifi.aware.AttachCallback
import android.net.wifi.aware.DiscoverySession
import android.net.wifi.aware.DiscoverySessionCallback
import android.net.wifi.aware.PeerHandle
import android.net.wifi.aware.SubscribeConfig
import android.net.wifi.aware.SubscribeDiscoverySession
import android.net.wifi.aware.WifiAwareManager
import android.net.wifi.aware.WifiAwareSession
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Wi-Fi Aware (NAN) peer discovery — EXPERIMENTAL / UNVERIFIED.
 *
 * Written without an Android SDK on the build machine, so it has never
 * been compiled. API notes: on compileSdk 34+, AttachCallback is the
 * top-level android.net.wifi.aware.AttachCallback (not the old nested
 * WifiAwareManager.AttachCallback), and onSubscribeStarted takes a
 * SubscribeDiscoverySession. If `flutter build apk` still fails, this
 * file plus the AWARE block in configureFlutterEngine are the first
 * suspects: delete them and the rest of the app builds without the
 * Aware panel.
 *
 * Honest scope: Wi-Fi Aware is *cooperative* discovery. It only sees
 * devices that are also publishing/subscribing the same service name —
 * it does NOT passively detect strangers' phones. For passive nearby
 * sensing, BLE advertisement scanning remains the useful sensor.
 */
class MainActivity : FlutterActivity() {
    companion object {
        private const val AWARE_METHOD = "rf_sentry/wifi_aware"
        private const val AWARE_EVENTS = "rf_sentry/wifi_aware_events"
        private const val MCAST_METHOD = "shepherd/multicast_lock"
        private const val WIFI_METHOD = "shepherd/wifi_sense"
        private const val WIFI_PERM_REQUEST = 9917
    }

    private var multicastLock: WifiManager.MulticastLock? = null
    private var wifiPermRequested = false

    private var eventSink: EventChannel.EventSink? = null
    private var discoverySession: DiscoverySession? = null
    private var awareSession: WifiAwareSession? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Multicast lock for CoT ingest (cot_listener.dart). Held only
        // while the listener is running.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MCAST_METHOD)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquire" -> result.success(acquireMulticastLock())
                    "release" -> {
                        releaseMulticastLock()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        // WiFi Vision ambient sensing source (wifi_sense.dart
        // AndroidWifiSource). Passive reads only: the connected AP's
        // RSSI and the system scan-results cache. startScan is
        // best-effort — Android throttles it (foreground ~4 per 2 min),
        // so a throttled survey simply returns the latest cached
        // results instead of failing.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WIFI_METHOD)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "connected" -> {
                        // Scan results accept FINE *or* NEARBY (33+),
                        // but WifiInfo SSID/BSSID only un-redact with
                        // FINE — a NEARBY-only grant gets its own error
                        // so the app can explain the dead fast poll
                        // instead of silently showing nothing.
                        when {
                            !hasWifiScanPermission() -> result.error(
                                "NO_PERMISSION",
                                "WiFi sensing needs Location permission", null)
                            !hasFineLocation() -> result.error(
                                "NO_FINE_LOCATION",
                                "Connected-AP sensing needs full Location " +
                                    "permission", null)
                            else -> result.success(connectedAp())
                        }
                    }
                    "survey" -> {
                        if (!hasWifiScanPermission()) {
                            result.error("NO_PERMISSION",
                                "WiFi sensing needs Location permission", null)
                        } else {
                            result.success(wifiSurvey())
                        }
                    }
                    "requestPermission" -> {
                        requestWifiPermissions()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        // --- AWARE block start (safe to delete; see class doc) ---
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AWARE_METHOD)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isAwareAvailable" -> result.success(isAwareAvailable())
                    "startDiscovery" -> {
                        val name = call.argument<String>("serviceName") ?: "shepherd"
                        result.success(startAwareDiscovery(name))
                    }
                    "stopDiscovery" -> {
                        stopAwareDiscovery()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, AWARE_EVENTS)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                    eventSink = sink
                }
                override fun onCancel(args: Any?) {
                    eventSink = null
                }
            })
        // --- AWARE block end ---
    }

    private fun acquireMulticastLock(): Boolean {
        return try {
            if (multicastLock?.isHeld == true) return true
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE)
                as? WifiManager ?: return false
            val lock = wifi.createMulticastLock("shepherd-cot")
            lock.setReferenceCounted(false)
            lock.acquire()
            multicastLock = lock
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun releaseMulticastLock() {
        try {
            multicastLock?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) {
        }
        multicastLock = null
    }

    override fun onDestroy() {
        releaseMulticastLock()
        stopAwareDiscovery()
        super.onDestroy()
    }

    /// Re-arm the prompt latch once the user has answered, so a later
    /// attempt (e.g. after they dismissed the dialog) can prompt again
    /// instead of staying dead for the rest of the process.
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == WIFI_PERM_REQUEST) {
            wifiPermRequested = false
        }
    }

    // --- WiFi Vision source helpers ---

    private fun wifiManager(): WifiManager? =
        applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager

    private fun hasFineLocation(): Boolean =
        ContextCompat.checkSelfPermission(
            this, Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED

    /// Scan results are location-derived data: Android gates them
    /// behind ACCESS_FINE_LOCATION, or (API 33+) NEARBY_WIFI_DEVICES.
    private fun hasWifiScanPermission(): Boolean {
        if (hasFineLocation()) return true
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            return ContextCompat.checkSelfPermission(
                this, Manifest.permission.NEARBY_WIFI_DEVICES
            ) == PackageManager.PERMISSION_GRANTED
        }
        return false
    }

    /// Prompt once per process; the Dart side also gates its calls, so
    /// a denied permission doesn't re-prompt on every 1 s poll.
    private fun requestWifiPermissions() {
        if (wifiPermRequested || hasWifiScanPermission()) return
        wifiPermRequested = true
        // Android 12+ (targetSdk 31+) silently IGNORES a request for
        // ACCESS_FINE_LOCATION alone: FINE must be requested together
        // with COARSE so the user can pick precise vs approximate.
        val perms = mutableListOf(
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.ACCESS_COARSE_LOCATION,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            perms.add(Manifest.permission.NEARBY_WIFI_DEVICES)
        }
        try {
            ActivityCompat.requestPermissions(this, perms.toTypedArray(),
                WIFI_PERM_REQUEST)
        } catch (_: Exception) {
        }
    }

    /// The connected AP, or null when not associated. connectionInfo is
    /// deprecated on API 31+ in favor of NetworkCallback TransportInfo,
    /// but with the scan permission held it still returns real values
    /// and needs no callback lifecycle — deliberate simplicity.
    @Suppress("DEPRECATION")
    private fun connectedAp(): Map<String, Any>? {
        return try {
            val info = wifiManager()?.connectionInfo ?: return null
            if (info.networkId == -1) return null
            // RSSI_INVALID (-127) shows up during association/roam
            // transitions with a valid networkId; fed to the baseline
            // it would fake a ~70 dB dip and a false disturbance.
            // A non-negative reading is likewise not a real RSSI.
            if (info.rssi <= -127 || info.rssi >= 0) return null
            val bssid = info.bssid?.lowercase() ?: return null
            // Redacted placeholder Android returns without permission.
            if (bssid == "02:00:00:00:00:00") return null
            mapOf(
                "ssid" to (info.ssid?.removeSurrounding("\"") ?: ""),
                "bssid" to bssid,
                "rssi" to info.rssi,
            )
        } catch (_: Exception) {
            null
        }
    }

    @Suppress("DEPRECATION")
    private fun wifiSurvey(): List<Map<String, Any>> {
        val wifi = wifiManager() ?: return emptyList()
        try {
            // Best-effort fresh scan; false just means throttled, and
            // the cached results below are still the latest known field.
            wifi.startScan()
        } catch (_: Exception) {
        }
        val connectedBssid = try {
            val b = wifi.connectionInfo?.bssid?.lowercase()
            // Redacted placeholder / absent: no AP is "the connected one"
            // (null == null must never mark every scan entry connected).
            if (b == null || b == "02:00:00:00:00:00") null else b
        } catch (_: Exception) {
            null
        }
        return try {
            wifi.scanResults.map { r ->
                mapOf<String, Any>(
                    "ssid" to (r.SSID ?: ""),
                    "bssid" to (r.BSSID?.lowercase() ?: ""),
                    "rssi" to r.level,
                    "capabilities" to (r.capabilities ?: ""),
                    "connected" to (connectedBssid != null &&
                        r.BSSID?.lowercase() == connectedBssid),
                    // ScanResult.timestamp is µs since boot — the Dart
                    // side uses it to tell a fresh scan from a throttled
                    // re-read of this same cache.
                    "tsMs" to (r.timestamp / 1000),
                )
            }
        } catch (_: SecurityException) {
            emptyList()
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun awareManager(): WifiAwareManager? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return null
        if (!packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_AWARE)) return null
        return getSystemService(Context.WIFI_AWARE_SERVICE) as? WifiAwareManager
    }

    private fun isAwareAvailable(): Boolean {
        return try {
            awareManager()?.isAvailable == true
        } catch (_: Exception) {
            false
        }
    }

    private fun startAwareDiscovery(serviceName: String): Boolean {
        if (!isAwareAvailable()) return false
        stopAwareDiscovery()
        val mgr = awareManager() ?: return false
        return try {
            mgr.attach(object : AttachCallback() {
                override fun onAttached(session: WifiAwareSession) {
                    awareSession = session
                    val config = SubscribeConfig.Builder()
                        .setServiceName(serviceName)
                        .build()
                    session.subscribe(config, object : DiscoverySessionCallback() {
                        override fun onSubscribeStarted(
                            s: SubscribeDiscoverySession
                        ) {
                            discoverySession = s
                        }

                        override fun onServiceDiscovered(
                            peerHandle: PeerHandle,
                            serviceSpecificInfo: ByteArray,
                            matchFilter: List<ByteArray>
                        ) {
                            eventSink?.success(
                                mapOf("peerId" to peerHandle.hashCode().toString())
                            )
                        }

                        override fun onSessionTerminated() {
                            discoverySession = null
                        }
                    }, null)
                }

                override fun onAttachFailed() {
                    eventSink?.error("ATTACH_FAILED", "Wi-Fi Aware attach failed", null)
                }
            }, null)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun stopAwareDiscovery() {
        try {
            discoverySession?.close()
        } catch (_: Exception) {
        }
        try {
            awareSession?.close()
        } catch (_: Exception) {
        }
        discoverySession = null
        awareSession = null
    }
}
