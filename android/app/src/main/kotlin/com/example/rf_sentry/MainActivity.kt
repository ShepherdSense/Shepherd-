package com.example.rf_sentry

import android.content.Context
import android.content.pm.PackageManager
import android.net.wifi.WifiManager
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
    }

    private var multicastLock: WifiManager.MulticastLock? = null

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
        super.onDestroy()
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
