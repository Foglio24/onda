package com.onda.seaglass.audio.karaoke

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteOrder
import java.nio.ShortBuffer
import java.nio.channels.FileChannel
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * A song and its vocals as the karaoke keeps them: both 16-bit stereo at 48 kHz (the engine's
 * rate), in files mapped into memory. The song is the app's own decode of it, from the start to the
 * end in one pass, so its frames are the engine's frames exactly (a seek in a WebM can land a few
 * milliseconds off; the stems never depend on one). The vocals are filled piece by piece in any
 * order (the piece being played first); neighbouring pieces overlap by half a second and are
 * crossfaded. Written by the separation, read by the engine's [KaraokeTap]: [revision] (volatile)
 * is raised after each piece, so what was written before is seen by whoever reads it after.
 */
class KaraokeStems private constructor(
    val videoId: String,
    /** The song's sample rate, and its length in frames at that rate. */
    val rate: Int,
    val frames: Int,
    private val geometry: Geometry,
    private val meta: File,
    private val channel: FileChannel,
    private val vocals: ShortBuffer,
    private val songChannel: FileChannel,
    private val song: ShortBuffer,
) : AutoCloseable {
    /** The model's pieces, at its 44.1 kHz: every [Geometry.step] frames, [MdxSpectrogram.MAX_PIECE] long. */
    class Geometry(rate: Int, frames: Int) {
        val modelFrames = (frames.toLong() * MdxSpectrogram.SAMPLE_RATE / rate).toInt()
        // Piece starts land on whole frames at both rates (48 kHz and 44.1 kHz meet every 160 and 147).
        private val unit = MdxSpectrogram.SAMPLE_RATE / gcd(rate, MdxSpectrogram.SAMPLE_RATE)
        val step = (MdxSpectrogram.MAX_PIECE - OVERLAP) / unit * unit
        val pieces = maxOf(1, (modelFrames - OVERLAP + step - 1) / step)
    }

    val pieces: Int get() = geometry.pieces
    private val done = BooleanArray(geometry.pieces)
    private val overlap = native(OVERLAP)
    private val ready = BooleanArray(frames / BLOCK + 1)

    @Volatile var revision = 0
        private set

    val complete: Boolean get() = done.all { it }
    val doneCount: Int get() = done.count { it }

    fun isDone(piece: Int) = done[piece]

    /** Where piece [k] starts in the model's frames, and how many it has. */
    fun modelStart(k: Int) = k * geometry.step
    fun modelCount(k: Int) = min(MdxSpectrogram.MAX_PIECE, geometry.modelFrames - modelStart(k)).coerceAtLeast(0)

    /** The same in the song's frames. */
    fun start(k: Int) = native(modelStart(k))
    fun end(k: Int) = min(frames, native(modelStart(k) + modelCount(k)))

    /** The piece that plays at [frame] (the first of two where they overlap). */
    fun pieceAt(frame: Int): Int =
        (frame.toLong() * MdxSpectrogram.SAMPLE_RATE / rate / geometry.step).toInt().coerceIn(0, pieces - 1)

    private fun native(modelFrame: Int) = (modelFrame.toLong() * rate / MdxSpectrogram.SAMPLE_RATE).toInt()

    /** Writes piece [k]'s vocals ([values]: interleaved stereo from [start] (k)), crossfaded with its done neighbours. */
    fun write(k: Int, values: FloatArray) {
        val from = start(k)
        val to = end(k)
        val count = min(values.size / 2, to - from)
        val leftShared = k > 0
        val rightShared = k + 1 < pieces
        val nextStart = if (rightShared) start(k + 1) else Int.MAX_VALUE
        for (i in 0 until count) {
            val frame = from + i
            for (c in 0..1) {
                val index = frame * 2 + c
                val value = values[i * 2 + c]
                val mixed = when {
                    leftShared && i < overlap && done[k - 1] -> {
                        // Shared with the piece before (written already): it fades out as this one fades in.
                        val w = i.toFloat() / overlap
                        vocals.get(index) / 32767f * (1 - w) + value * w
                    }
                    rightShared && frame >= nextStart && done[k + 1] -> {
                        // Shared with the piece after (written already): this one fades out as it comes in.
                        val w = minOf(1f, (frame - nextStart).toFloat() / overlap)
                        value * (1 - w) + vocals.get(index) / 32767f * w
                    }
                    else -> value
                }
                vocals.put(index, (mixed.coerceIn(-1f, 1f) * 32767f).roundToInt().toShort())
            }
        }
        done[k] = true
        markReady(k)
        revision++
        saveMeta()
    }

    /** Whether a done piece covers [frame]. */
    private fun covered(frame: Int): Boolean {
        if (frame < 0 || frame >= frames) return false
        val k = pieceAt(frame)
        if (frame < end(k) && done[k]) return true
        return k > 0 && frame < end(k - 1) && done[k - 1]
    }

    /** Marks the blocks around piece [k] that done pieces now cover entirely. */
    private fun markReady(k: Int) {
        val first = maxOf(0, start(k) / BLOCK - 1)
        val last = minOf(ready.size - 1, end(k) / BLOCK + 1)
        for (b in first..last) {
            if (ready[b]) continue
            val from = b * BLOCK
            val to = minOf(frames, from + BLOCK)
            if (from >= to) continue
            // Coverage changes only where pieces start or end: check there and at the block's ends.
            val edges = mutableListOf(from, to - 1)
            for (piece in maxOf(0, k - 2)..minOf(pieces - 1, k + 2)) {
                for (edge in listOf(start(piece), end(piece))) if (edge in from until to) {
                    edges += edge
                    if (edge - 1 >= from) edges += edge - 1
                }
            }
            if (edges.all(::covered)) ready[b] = true
        }
    }

    /** Whether the vocals are there for [count] frames from [frame]. Read the [revision] first. */
    fun isReady(frame: Long, count: Int): Boolean {
        if (frame < 0 || frame + count > frames) return false
        val first = (frame / BLOCK).toInt()
        val last = ((frame + count - 1) / BLOCK).toInt()
        for (b in first..last) if (!ready[b]) return false
        return true
    }

    /** The left and right vocals at [frame], -1…1. */
    fun left(frame: Int): Float = vocals.get(frame * 2) / 32768f
    fun right(frame: Int): Float = vocals.get(frame * 2 + 1) / 32768f

    /** The song itself (as the app decoded it) at [frame], -1…1. */
    fun songLeft(frame: Int): Float = song.get(frame * 2) / 32768f
    fun songRight(frame: Int): Float = song.get(frame * 2 + 1) / 32768f

    /** Reads ahead from [frame], so the player finds those pages in memory rather than on the disk. */
    fun touch(frame: Int, count: Int): Int {
        var sum = 0
        var index = frame.coerceAtLeast(0) * 2
        val last = min(frames, frame + count) * 2
        while (index < last) {
            sum += vocals.get(index) + song.get(index)
            index += 2048
        }
        return sum
    }

    private fun saveMeta() {
        runCatching {
            meta.writeText(JSONObject().put("rate", rate).put("frames", frames).put("done", JSONArray(done.toList())).toString())
        }
    }

    override fun close() {
        runCatching { channel.close() }
        runCatching { songChannel.close() }
    }

    companion object {
        /** Neighbouring pieces overlap by half a second (at the model's rate). */
        const val OVERLAP = 22_050
        /** The player's readiness is checked in blocks this many frames long. */
        const val BLOCK = 2048

        private fun gcd(a: Int, b: Int): Int = if (b == 0) a else gcd(b, a % b)

        const val RATE = 48_000

        private fun songFile(folder: File, videoId: String) = File(folder, "$videoId.song")

        /** The frames of the song kept in [folder] (its whole decode), or null when there is none. */
        fun songFrames(folder: File, videoId: String): Int? =
            songFile(folder, videoId).takeIf { it.isFile && it.length() > 0 && it.length() % 4 == 0L }?.let { (it.length() / 4).toInt() }

        /**
         * Decodes a song whole into [folder] (16-bit stereo, 48 kHz) from [read] (frames into the buffer
         * as interleaved floats; 0 at the end) and returns its length in frames. More than [limit]
         * frames, or a decode that fails: nothing is kept.
         */
        fun writeSong(folder: File, videoId: String, limit: Int, read: (FloatArray, Int) -> Int, progress: (Int) -> Unit = {}): Int {
            folder.mkdirs()
            val part = File(folder, "$videoId.song.part")
            var frames = 0
            try {
                RandomAccessFile(part, "rw").use { out ->
                    out.setLength(0)
                    val block = FloatArray(4096 * 2)
                    val bytes = java.nio.ByteBuffer.allocate(4096 * 4).order(ByteOrder.LITTLE_ENDIAN)
                    while (true) {
                        val n = read(block, 4096)
                        if (n <= 0) break
                        frames += n
                        if (frames > limit) throw java.io.IOException("The song is too long")
                        bytes.clear()
                        for (i in 0 until n * 2) bytes.putShort((block[i].coerceIn(-1f, 1f) * 32767f).roundToInt().toShort())
                        out.write(bytes.array(), 0, n * 4)
                        progress(frames)
                    }
                }
                if (frames == 0) throw java.io.IOException("Nothing was decoded")
            } catch (e: Exception) {
                part.delete()
                throw e
            }
            val file = songFile(folder, videoId)
            file.delete()
            if (!part.renameTo(file)) {
                part.delete()
                throw java.io.IOException("Couldn't keep the song")
            }
            return frames
        }

        /**
         * The song's stems in [folder]: what was separated before (same length), else a new file. The
         * song must be there already ([writeSong]).
         */
        fun open(folder: File, videoId: String, frames: Int): KaraokeStems {
            folder.mkdirs()
            val rate = RATE
            val file = File(folder, "$videoId.vocals")
            val meta = File(folder, "$videoId.json")
            val song = songFile(folder, videoId)
            require(song.length() == frames * 4L) { "The song's file doesn't match its length" }
            val previous = runCatching { JSONObject(meta.readText()) }.getOrNull()
                ?.takeIf { it.getInt("rate") == rate && it.getInt("frames") == frames && file.length() == frames * 4L }
            if (previous == null) {
                file.delete()
                meta.delete()
            }
            val channel = RandomAccessFile(file, "rw").channel
            val mapped = channel.map(FileChannel.MapMode.READ_WRITE, 0, frames * 4L).order(ByteOrder.LITTLE_ENDIAN)
            val songChannel = RandomAccessFile(song, "r").channel
            val songMapped = songChannel.map(FileChannel.MapMode.READ_ONLY, 0, frames * 4L).order(ByteOrder.LITTLE_ENDIAN)
            val stems = KaraokeStems(videoId, rate, frames, Geometry(rate, frames), meta, channel, mapped.asShortBuffer(), songChannel, songMapped.asShortBuffer())
            // The pieces done before.
            val doneBefore = previous?.optJSONArray("done")
            if (doneBefore != null && doneBefore.length() == stems.pieces) {
                for (k in 0 until stems.pieces) if (doneBefore.optBoolean(k)) stems.done[k] = true
                for (k in 0 until stems.pieces) if (stems.done[k]) stems.markReady(k)
            }
            file.setLastModified(System.currentTimeMillis())
            song.setLastModified(System.currentTimeMillis())
            return stems
        }

        /** Keeps the vocals of the newest [keep] songs. */
        fun prune(folder: File, keep: Int, except: String?) {
            // A file still mapped by a song that plays can't be deleted on Windows: it is tried again later.
            folder.listFiles { f -> f.name.endsWith(".song") }
                ?.filter { it.nameWithoutExtension != except }
                ?.sortedByDescending { it.lastModified() }
                ?.drop(keep - 1)
                ?.forEach {
                    val id = it.nameWithoutExtension
                    runCatching { it.delete() }
                    runCatching { File(folder, "$id.vocals").delete() }
                    runCatching { File(folder, "$id.json").delete() }
                }
        }
    }
}
