package com.onda.seaglass

import com.onda.seaglass.account.SecureStore
import com.onda.seaglass.audio.Decoder
import com.onda.seaglass.audio.FileSource
import com.onda.seaglass.audio.JavaSoundSink
import java.io.File

/**
 * `Seaglass.exe --self-test`: what CI runs on Windows after installing, to know the installed app
 * works there and not only on the build machine: FFmpeg's and ONNX Runtime's libraries load, FFmpeg decodes, Windows's
 * audio outputs are listed, and the user's secrets can be protected (DPAPI). Exit code 0 when fine.
 */
object SelfTest {
    fun run(): Int {
        var failures = 0
        // The installed launcher has no console: CI reads the report from SEAGLASS_SELFTEST_OUT.
        val report = StringBuilder()
        fun println(line: String) {
            kotlin.io.println(line)
            report.appendLine(line)
        }
        fun check(ok: Boolean, what: String) {
            println((if (ok) "ok   " else "FAIL ") + what)
            if (!ok) failures++
        }
        runCatching {
            val file = File.createTempFile("seaglass-selftest", ".webm").apply { deleteOnExit() }
            SelfTest::class.java.classLoader.getResourceAsStream("selftest.webm")!!.use { input -> file.outputStream().use { input.copyTo(it) } }
            Decoder(FileSource(file)).use { decoder ->
                val block = FloatArray(4096)
                var frames = 0L
                while (true) {
                    val count = decoder.read(block, 2048)
                    if (count == 0) break
                    frames += count
                }
                check(decoder.codecName == "Opus" && frames > Decoder.RATE * 2.5, "FFmpeg decodes Opus (${frames / Decoder.RATE.toDouble()} s)")
            }
        }.onFailure { check(false, "FFmpeg: $it") }
        // The karaoke's vocal model runs on ONNX Runtime: its Windows library (and the Visual C++ runtime
        // it needs) must load on the installed app's own Java.
        runCatching {
            com.onda.seaglass.audio.karaoke.OrtNative.prepare()
            val environment = ai.onnxruntime.OrtEnvironment.getEnvironment()
            // A tensor made and read back: the Java side and the native library agree.
            ai.onnxruntime.OnnxTensor.createTensor(environment, java.nio.FloatBuffer.wrap(floatArrayOf(1f, 2f)), longArrayOf(2)).use { tensor ->
                val back = FloatArray(2)
                tensor.floatBuffer.get(back)
                check(back[0] == 1f && back[1] == 2f, "ONNX Runtime loads and holds a tensor (karaoke)")
            }
        }.onFailure { check(false, "ONNX Runtime: $it") }
        runCatching {
            val devices = JavaSoundSink.devices()
            println("     audio outputs: $devices")
        }.onFailure { check(false, "audio outputs: $it") }
        if (WindowsIntegration.isWindows) {
            runCatching {
                SecureStore.set("selftest", "secret")
                check(SecureStore.get("selftest") == "secret", "DPAPI keeps a secret")
                SecureStore.set("selftest", null)
            }.onFailure { check(false, "DPAPI: $it") }
        }
        println(if (failures == 0) "Self-test passed" else "Self-test: $failures failed")
        System.getenv("SEAGLASS_SELFTEST_OUT")?.let { runCatching { File(it).writeText(report.toString()) } }
        return if (failures == 0) 0 else 1
    }
}
