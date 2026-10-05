package com.feijian.lan

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Holds a `WifiManager.MulticastLock` for the life of the app.
 *
 * The manifest declares `CHANGE_WIFI_MULTICAST_STATE`, which grants the
 * permission to take the lock — it does not take it. Without an `acquire()`,
 * the Wi-Fi firmware drops multicast frames to save power, the socket-level
 * `joinMulticast` still succeeds, and UDP discovery receives nothing at all
 * while looking perfectly healthy from the inside. See `lib/platform/wifi_lock.dart`.
 *
 * Held rather than acquired per announce: this app exists to notice the other
 * device appearing, so the lock must be on at the moment it announces, not
 * around our own sends.
 */
class MainActivity : FlutterActivity() {

    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquire" -> result.success(acquireMulticastLock())
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * True when the lock is held. Returns false rather than throwing: a device
     * with no Wi-Fi radio (or an emulator on Ethernet) cannot take the lock, and
     * refusing to start discovery over that would trade a degraded feature for
     * no app at all. Broadcast does not need the lock.
     */
    private fun acquireMulticastLock(): Boolean {
        if (multicastLock?.isHeld == true) {
            return true
        }
        return try {
            val wifi = applicationContext
                .getSystemService(Context.WIFI_SERVICE) as? WifiManager
                ?: return false
            // Not reference counted, so one release in onDestroy is enough no
            // matter how many times the Dart side asks. With the default
            // counting behaviour, a second acquire() whose release never came
            // would leak the lock for the rest of the process's life.
            val lock = wifi.createMulticastLock(LOCK_TAG).apply {
                setReferenceCounted(false)
                acquire()
            }
            multicastLock = lock
            true
        } catch (e: Exception) {
            // SecurityException when the permission was stripped by a vendor
            // ROM, UnsupportedOperationException on some emulators.
            android.util.Log.w(LOCK_TAG, "could not acquire the multicast lock", e)
            false
        }
    }

    override fun onDestroy() {
        // Released explicitly: a lock finalised while still held leaves the
        // firmware filtering multicast for whatever runs next.
        if (multicastLock?.isHeld == true) {
            multicastLock?.release()
        }
        multicastLock = null
        super.onDestroy()
    }

    private companion object {
        const val CHANNEL = "com.feijian.lan/wifi_lock"
        const val LOCK_TAG = "feijian"
    }
}
