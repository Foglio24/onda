package com.onda.seaglass.playback

import android.content.Context
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioMixerAttributes
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.annotation.OptIn
import androidx.annotation.RequiresApi
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.audio.AudioSink
import com.onda.seaglass.core.tr
import com.onda.seaglass.data.Prefs
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import android.media.AudioAttributes as PlatformAttributes

/**
 * Bit-perfect output to a USB DAC (Android 14 and later), as in LastWave: the song's samples reach
 * the DAC as decoded, at their own sample rate, without Android's mixer resampling them or other
 * sounds mixed in. Each song's rate (48 kHz for Opus, 44.1 kHz for AAC) is asked of the DAC as it
 * starts. The volume is then the DAC's (or the phone's volume keys, which Android passes to it):
 * "Volume uniforme" and the crossfade stay off, since they change the samples.
 */
@OptIn(UnstableApi::class)
object BitPerfect {
    sealed interface Status {
        data object Off : Status
        data object Unsupported : Status
        data object NoDac : Status
        data class Active(val device: String, val sampleRate: Int, val bits: Int) : Status
        data class Refused(val device: String) : Status
    }

    private val _status = MutableStateFlow<Status>(Status.Off)
    val status: StateFlow<Status> = _status

    /** True while samples go to the DAC untouched: nothing may change the volume. */
    val active: Boolean get() = _status.value is Status.Active

    val supported: Boolean get() = Build.VERSION.SDK_INT >= 34

    fun describe(status: Status): String = when (status) {
        Status.Off -> tr("Disattivato")
        Status.Unsupported -> tr("Richiede Android 14 o successivi")
        Status.NoDac -> tr("Collega un DAC USB")
        is Status.Active -> tr("Attivo: %@ · %@ kHz · %lld bit", status.device, formatRate(status.sampleRate), status.bits)
        is Status.Refused -> tr("%@ non accetta l'audio bit-perfect", status.device)
    }

    private fun formatRate(rate: Int) = if (rate % 1000 == 0) "${rate / 1000}" else String.format(java.util.Locale.ROOT, "%.1f", rate / 1000.0)

    /** Follows the player and the USB devices; call once the player exists. */
    fun attach(context: Context, player: ExoPlayer): () -> Unit {
        if (!supported) {
            _status.value = if (Prefs.bitPerfect.value) Status.Unsupported else Status.Off
            return {}
        }
        return Controller(context, player).start()
    }

    @RequiresApi(34)
    private class Controller(context: Context, private val player: ExoPlayer) {
        private val audio = context.getSystemService(AudioManager::class.java)
        private val attributes = PlatformAttributes.Builder()
            .setUsage(PlatformAttributes.USAGE_MEDIA)
            .setContentType(PlatformAttributes.CONTENT_TYPE_MUSIC)
            .build()
        private var applied: Pair<AudioDeviceInfo, AudioMixerAttributes>? = null
        private val handler = Handler(Looper.getMainLooper())

        private val devices = object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) = update(null)
            override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) = update(null)
        }

        private val analytics = object : AnalyticsListener {
            override fun onAudioTrackInitialized(eventTime: AnalyticsListener.EventTime, config: AudioSink.AudioTrackConfig) {
                update(config)
            }
        }

        private val setting = Prefs.bitPerfect

        fun start(): () -> Unit {
            audio.registerAudioDeviceCallback(devices, handler)
            player.addAnalyticsListener(analytics)
            val watcher = Runnable { update(null) }
            var last = setting.value
            val poll = object : Runnable {
                override fun run() {
                    if (setting.value != last) {
                        last = setting.value
                        watcher.run()
                    }
                    handler.postDelayed(this, 500)
                }
            }
            handler.post(poll)
            update(null)
            return {
                handler.removeCallbacks(poll)
                audio.unregisterAudioDeviceCallback(devices)
                player.removeAnalyticsListener(analytics)
                clear()
            }
        }

        private fun usbOutput(): AudioDeviceInfo? = audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS).firstOrNull {
            it.type == AudioDeviceInfo.TYPE_USB_HEADSET || it.type == AudioDeviceInfo.TYPE_USB_DEVICE
        }

        /** Asks the DAC for the playing song's format; [config] is the audio track just opened, if any. */
        fun update(config: AudioSink.AudioTrackConfig?) {
            if (!setting.value) {
                clear()
                _status.value = Status.Off
                return
            }
            val device = usbOutput()
            if (device == null) {
                clear()
                _status.value = Status.NoDac
                return
            }
            val name = device.productName?.toString()?.takeIf { it.isNotBlank() } ?: "USB"
            val rate = config?.sampleRate ?: player.audioFormat?.sampleRate?.takeIf { it > 0 } ?: 48_000
            val encoding = config?.encoding ?: AudioFormat.ENCODING_PCM_16BIT
            val current = applied
            if (current != null && current.first.id == device.id && current.second.format.sampleRate == rate &&
                current.second.format.encoding == encoding
            ) {
                return
            }
            val candidates = audio.getSupportedMixerAttributes(device)
                .filter { it.mixerBehavior == AudioMixerAttributes.MIXER_BEHAVIOR_BIT_PERFECT && it.format.sampleRate == rate }
            val chosen = candidates.firstOrNull { it.format.encoding == encoding } ?: candidates.firstOrNull()
            if (chosen == null || !audio.setPreferredMixerAttributes(attributes, device, chosen)) {
                clear()
                _status.value = Status.Refused(name)
                return
            }
            applied = device to chosen
            val bits = when (chosen.format.encoding) {
                AudioFormat.ENCODING_PCM_24BIT_PACKED -> 24
                AudioFormat.ENCODING_PCM_32BIT, AudioFormat.ENCODING_PCM_FLOAT -> 32
                else -> 16
            }
            _status.value = Status.Active(name, rate, bits)
            player.volume = 1f
            // A new audio session makes the player open its output again, now through the DAC's
            // mixer; that output's own report then finds the mixer already set, so this ends here.
            player.setAudioSessionId(audio.generateAudioSessionId())
        }

        private fun clear() {
            val current = applied ?: return
            runCatching { audio.clearPreferredMixerAttributes(attributes, current.first) }
            applied = null
            player.setAudioSessionId(audio.generateAudioSessionId())
        }
    }
}
