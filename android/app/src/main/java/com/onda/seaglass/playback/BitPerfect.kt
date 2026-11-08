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
 * Bit-perfect output (Android 14 and later), as in LastWave: the song's samples reach the output as
 * decoded, at their own sample rate, without Android's mixer resampling them or other sounds mixed
 * in. It works on every output Android says can take it: USB DACs and USB-C headphones and dongles,
 * USB docks and accessories, and on the phones whose makers support it, wired headphones, line and
 * HDMI outputs too. The output used is the one the music is going to. Bluetooth headphones can't:
 * Bluetooth always encodes the sound again (SBC, AAC, aptX, LDAC). Each song's rate (48 kHz for Opus,
 * 44.1 kHz for AAC) is asked of the output as it starts. The volume is then the device's (or the
 * phone's volume keys, which Android passes to it): "Volume uniforme" and the crossfade stay off,
 * since they change the samples.
 */
@OptIn(UnstableApi::class)
object BitPerfect {
    sealed interface Status {
        data object Off : Status
        data object Unsupported : Status
        /** Nothing connected that can take it (and nothing better to say about where the music goes). */
        data object NoDac : Status
        /** The music goes to Bluetooth, which encodes it again. */
        data class Bluetooth(val device: String) : Status
        /** The output the music goes to can't take it (the phone's speaker, wired headphones on most phones). */
        data class NotCapable(val device: String) : Status
        data class Active(val device: String, val sampleRate: Int, val bits: Int) : Status
        data class Refused(val device: String) : Status
        /** The output takes bit-perfect audio, but not at the song's rate. */
        data class RateRefused(val device: String, val sampleRate: Int) : Status
    }

    private val _status = MutableStateFlow<Status>(Status.Off)
    val status: StateFlow<Status> = _status

    /** True while samples go to the output untouched: nothing may change the volume. */
    val active: Boolean get() = _status.value is Status.Active

    val supported: Boolean get() = Build.VERSION.SDK_INT >= 34

    fun describe(status: Status): String = when (status) {
        Status.Off -> tr("Disattivato")
        Status.Unsupported -> tr("Richiede Android 14 o successivi")
        Status.NoDac -> tr("Collega un DAC USB")
        is Status.Bluetooth -> tr("%@ è Bluetooth: l'audio viene ricodificato, il bit-perfect non è possibile.", status.device)
        is Status.NotCapable -> tr("%@ non supporta il bit-perfect: collega un DAC o delle cuffie USB.", status.device)
        is Status.Active -> tr("Attivo: %@ · %@ kHz · %lld bit", status.device, formatRate(status.sampleRate), status.bits)
        is Status.Refused -> tr("%@ non accetta l'audio bit-perfect", status.device)
        is Status.RateRefused -> tr("%@ non accetta l'audio bit-perfect a %@ kHz", status.device, formatRate(status.sampleRate))
    }

    private fun formatRate(rate: Int) = if (rate % 1000 == 0) "${rate / 1000}" else String.format(java.util.Locale.ROOT, "%.1f", rate / 1000.0)

    /** Follows the player and the outputs; call once the player exists. */
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
            var lastRoute = routedIds()
            var ticks = 0
            val poll = object : Runnable {
                override fun run() {
                    // The setting, every half second; where the music goes (chosen in Android's
                    // output switcher, say), every two seconds while bit-perfect is on.
                    val route = if (setting.value && ticks++ % 4 == 0) routedIds() else lastRoute
                    if (setting.value != last || route != lastRoute) {
                        last = setting.value
                        lastRoute = route
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

        /** The output's bit-perfect formats (empty when it has none). */
        private fun bitPerfectFormats(device: AudioDeviceInfo): List<AudioMixerAttributes> =
            runCatching { audio.getSupportedMixerAttributes(device) }.getOrDefault(emptyList())
                .filter { it.mixerBehavior == AudioMixerAttributes.MIXER_BEHAVIOR_BIT_PERFECT }

        /**
         * The output to use: where the music goes now when it can take bit-perfect audio; otherwise
         * the one that can (USB first). Null with the reason to show when there's none.
         */
        private fun output(): Pair<AudioDeviceInfo?, Status?> {
            val routed = runCatching { audio.getAudioDevicesForAttributes(attributes) }.getOrDefault(emptyList())
                .mapNotNull { routedDevice -> audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS).firstOrNull { it.id == routedDevice.id } }
            routed.firstOrNull { bitPerfectFormats(it).isNotEmpty() }?.let { return it to null }
            val where = routed.firstOrNull()
            if (where == null) {
                // Android doesn't say where the music goes: the output that can take it, USB first.
                val capable = audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                    .filter { bitPerfectFormats(it).isNotEmpty() }
                    .sortedBy { if (it.type == AudioDeviceInfo.TYPE_USB_HEADSET || it.type == AudioDeviceInfo.TYPE_USB_DEVICE) 0 else 1 }
                return capable.firstOrNull() to Status.NoDac
            }
            return null to when {
                isBluetooth(where) -> Status.Bluetooth(nameOf(where))
                where.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER || where.type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> Status.NoDac
                else -> Status.NotCapable(nameOf(where))
            }
        }

        private fun isBluetooth(device: AudioDeviceInfo) = device.type in setOf(
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, AudioDeviceInfo.TYPE_BLUETOOTH_SCO, AudioDeviceInfo.TYPE_BLE_HEADSET,
            AudioDeviceInfo.TYPE_BLE_SPEAKER, AudioDeviceInfo.TYPE_BLE_BROADCAST, AudioDeviceInfo.TYPE_HEARING_AID,
        )

        /** The device's own name, or what it is (wired headphones report the phone's name). */
        private fun nameOf(device: AudioDeviceInfo): String = when (device.type) {
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_WIRED_HEADSET -> tr("Cuffie")
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER, AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> tr("Altoparlante del telefono")
            else -> device.productName?.toString()?.takeIf { it.isNotBlank() && it != Build.MODEL } ?: when (device.type) {
                AudioDeviceInfo.TYPE_HDMI, AudioDeviceInfo.TYPE_HDMI_ARC, AudioDeviceInfo.TYPE_HDMI_EARC -> "HDMI"
                else -> "USB"
            }
        }

        /** The outputs the music goes to now, to notice when it moves without a device coming or going. */
        fun routedIds(): List<Int> =
            runCatching { audio.getAudioDevicesForAttributes(attributes).map { it.id } }.getOrDefault(emptyList())

        /** Asks the output for the playing song's format; [config] is the audio track just opened, if any. */
        fun update(config: AudioSink.AudioTrackConfig?) {
            if (!setting.value) {
                clear()
                _status.value = Status.Off
                return
            }
            val (device, reason) = output()
            if (device == null) {
                clear()
                _status.value = reason ?: Status.NoDac
                return
            }
            val name = nameOf(device)
            val rate = config?.sampleRate ?: player.audioFormat?.sampleRate?.takeIf { it > 0 } ?: 48_000
            val encoding = config?.encoding ?: AudioFormat.ENCODING_PCM_16BIT
            val current = applied
            if (current != null && current.first.id == device.id && current.second.format.sampleRate == rate &&
                current.second.format.encoding == encoding
            ) {
                return
            }
            val formats = bitPerfectFormats(device)
            val atRate = formats.filter { it.format.sampleRate == rate }
            if (atRate.isEmpty()) {
                clear()
                _status.value = Status.RateRefused(name, rate)
                return
            }
            // The player's samples as they are (16-bit): the output must take that very format.
            val chosen = atRate.firstOrNull { it.format.encoding == encoding }
            if (chosen == null || !audio.setPreferredMixerAttributes(attributes, device, chosen)) {
                clear()
                _status.value = Status.Refused(name)
                return
            }
            if (current != null && current.first.id != device.id) {
                runCatching { audio.clearPreferredMixerAttributes(attributes, current.first) }
            }
            applied = device to chosen
            val bits = when (chosen.format.encoding) {
                AudioFormat.ENCODING_PCM_24BIT_PACKED -> 24
                AudioFormat.ENCODING_PCM_32BIT, AudioFormat.ENCODING_PCM_FLOAT -> 32
                else -> 16
            }
            _status.value = Status.Active(name, rate, bits)
            player.volume = 1f
            // A new audio session makes the player open its output again, now through the bit-perfect
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
