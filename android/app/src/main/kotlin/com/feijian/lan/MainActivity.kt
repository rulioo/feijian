package com.feijian.lan

import android.content.ContentValues
import android.content.Context
import android.media.RingtoneManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

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

    /**
     * Where a gallery publish is copied on.
     *
     * A picture can be tens of megabytes, and the copy has to be off the
     * platform thread — `configureFlutterEngine`'s handler runs on it, and
     * blocking the thread that draws the app for the length of a disk write is
     * how a receive turns into a frozen UI. Single-threaded because the work is
     * disk-bound and two copies at once would only make both slower.
     */
    private val ioExecutor = Executors.newSingleThreadExecutor()

    /** Answers channel calls on, because [ioExecutor] is not allowed to. */
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquire" -> result.success(acquireMulticastLock())
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SOUND_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "play" -> result.success(playNotificationSound())
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, GALLERY_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "save" -> publishToGallery(
                        path = call.argument<String>("path"),
                        name = call.argument<String>("name"),
                        mime = call.argument<String>("mime"),
                        result = result,
                    )
                    else -> result.notImplemented()
                }
            }

        // Sent off the platform thread because it touches MediaStore. Safe here
        // and only here: the engine was just created, so no publish of ours can
        // be in flight for this to sweep up.
        ioExecutor.execute { sweepOrphanedPublishes(applicationContext) }
    }

    /**
     * Rings the device's notification tone once.
     *
     * Flutter's `SystemSound.play(SystemSoundType.alert)` is documented as
     * ignored on Android — it returns normally and plays nothing — which is why
     * this exists at all rather than the Dart side handling both platforms.
     *
     * `RingtoneManager` rather than a bundled asset or a `MediaPlayer` on one:
     * the notification tone is the sound this device already uses for "something
     * arrived", it is the one the user picked, and playing it keeps the
     * notification volume, the silent switch and Do-Not-Disturb in charge.
     *
     * Returns whether a tone was played. False rather than an exception when the
     * device has no default notification tone (a real configuration on stripped
     * ROMs): a message that arrives silently is a far better outcome than a
     * delivery that fails because it could not be announced.
     */
    private fun playNotificationSound(): Boolean {
        return try {
            val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
                ?: return false
            val ringtone = RingtoneManager.getRingtone(applicationContext, uri)
                ?: return false
            ringtone.play()
            true
        } catch (e: Exception) {
            android.util.Log.w(SOUND_TAG, "could not play the notification sound", e)
            false
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

    /**
     * Copies a received picture into `Pictures/Feijian`, where the gallery
     * indexes it like a photograph the camera took.
     *
     * Answers false rather than throwing for every way this can fail. It is
     * called on the receiving path of a transfer that has already succeeded —
     * the bytes are on disk and the chat says so — so a picture that did not
     * reach the album is a smaller disappointment than a transfer reported as
     * failed after it worked. See `lib/platform/gallery_saver.dart`.
     */
    private fun publishToGallery(
        path: String?,
        name: String?,
        mime: String?,
        result: MethodChannel.Result,
    ) {
        if (path == null || name == null) {
            result.success(false)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            // Nothing to fall back to. Below API 29 the way into the gallery is
            // a WRITE_EXTERNAL_STORAGE permission this app does not ask for and
            // a scan the user has to wait on; the picture is still in the chat
            // and still openable, which is the v1 answer for old devices.
            result.success(false)
            return
        }
        val context = applicationContext
        ioExecutor.execute {
            val published = try {
                copyIntoGallery(context, path, name, mime)
            } catch (e: Exception) {
                android.util.Log.w(GALLERY_TAG, "could not publish $name", e)
                false
            }
            postResult(result, published)
        }
    }

    /**
     * The copy itself, off the platform thread.
     *
     * The row is inserted **pending** and only published once the bytes are all
     * in. Without that the gallery is free to index a half-written file — the
     * insert is what announces the picture's existence — and show a torn image
     * that never repairs itself, because nothing will ever write the rest.
     */
    private fun copyIntoGallery(
        context: Context,
        path: String,
        name: String,
        mime: String?,
    ): Boolean {
        val source = File(path)
        if (!source.isFile) {
            // A publish asked for a file the app cannot see. Worth distinguishing
            // from a write failure in a log, though the answer to the caller is
            // the same.
            android.util.Log.w(GALLERY_TAG, "no file to publish at $path")
            return false
        }

        val resolver = context.contentResolver
        val values = ContentValues().apply {
            // The name the album shows. A name already there is not an error and
            // is not handled here: MediaStore appends a suffix of its own rather
            // than overwriting, and picking a free name first would be a race
            // against every other writer on the device.
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(
                MediaStore.MediaColumns.RELATIVE_PATH,
                "${Environment.DIRECTORY_PICTURES}/$GALLERY_FOLDER",
            )
            put(MediaStore.MediaColumns.IS_PENDING, 1)
            // Only when the caller worked one out. Left off, MediaStore infers
            // the type from the name's extension — which beats writing a
            // placeholder that the gallery would then believe.
            if (mime != null) {
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
            }
        }

        val collection = MediaStore.Images.Media
            .getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val uri = resolver.insert(collection, values) ?: return false

        var published = false
        try {
            val written = resolver.openOutputStream(uri)?.use { out ->
                source.inputStream().use { input -> input.copyTo(out) }
                true
            } ?: false
            if (written) {
                // Clearing the flag is what puts it in the album. Everything up
                // to here has been invisible.
                val ready = ContentValues().apply {
                    put(MediaStore.MediaColumns.IS_PENDING, 0)
                }
                published = resolver.update(uri, ready, null, null) > 0
            }
            return published
        } finally {
            if (!published) {
                // A pending row left behind holds its bytes and shows up
                // nowhere — the gallery hides it, the file manager cannot see
                // it, and the user has no way to find it. Deleting is the only
                // cleanup there is.
                resolver.delete(uri, null, null)
            }
        }
    }

    /**
     * Deletes publishes of ours that never finished — a process killed between
     * the insert and the flag being cleared.
     *
     * Nothing else ever removes them: [copyIntoGallery]'s `finally` does not run
     * if the process is killed, and the row is invisible precisely because it
     * was never published. Left alone these accumulate as disk the user cannot
     * see and cannot reclaim.
     *
     * Only our own folder is touched. Names in `RELATIVE_PATH` are also what
     * keeps this from reaching another app's unfinished write.
     */
    private fun sweepOrphanedPublishes(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return
        }
        try {
            val collection = MediaStore.Images.Media
                .getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            val removed = context.contentResolver.delete(
                collection,
                "${MediaStore.MediaColumns.IS_PENDING}=1 AND "
                    + "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ?",
                arrayOf("${Environment.DIRECTORY_PICTURES}/$GALLERY_FOLDER%"),
            )
            if (removed > 0) {
                android.util.Log.i(
                    GALLERY_TAG,
                    "removed $removed unfinished gallery publishes",
                )
            }
        } catch (e: Exception) {
            android.util.Log.w(GALLERY_TAG, "could not sweep unfinished publishes", e)
        }
    }

    /**
     * Answers a channel call from a worker thread by hopping to the one the
     * channel is allowed to be answered on.
     *
     * Guarded because the engine may be gone by the time the copy finishes —
     * rotating the phone during a large publish destroys it — and a reply sent
     * through a torn-down messenger surfaces as an exception on the main thread,
     * which is a crash. Losing the answer costs a log line on the Dart side; the
     * picture is in the album either way.
     */
    private fun postResult(result: MethodChannel.Result, value: Boolean) {
        mainHandler.post {
            try {
                result.success(value)
            } catch (e: Exception) {
                android.util.Log.w(GALLERY_TAG, "no one left to answer", e)
            }
        }
    }

    override fun onDestroy() {
        // Released explicitly: a lock finalised while still held leaves the
        // firmware filtering multicast for whatever runs next.
        if (multicastLock?.isHeld == true) {
            multicastLock?.release()
        }
        multicastLock = null
        // A copy already running is allowed to finish — shutdown() only refuses
        // new work — which is what makes destroying mid-publish land the picture
        // rather than leave a pending row for the sweep to collect.
        ioExecutor.shutdown()
        super.onDestroy()
    }

    private companion object {
        const val CHANNEL = "com.feijian.lan/wifi_lock"
        const val SOUND_CHANNEL = "com.feijian.lan/notification_sound"
        const val GALLERY_CHANNEL = "com.feijian.lan/gallery_saver"
        const val LOCK_TAG = "feijian"
        const val SOUND_TAG = "feijian"
        const val GALLERY_TAG = "feijian"

        /** The album the user finds received pictures in. */
        const val GALLERY_FOLDER = "Feijian"
    }
}
