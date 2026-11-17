package com.onda.seaglass.audio.karaoke

import com.onda.seaglass.WindowsIntegration
import com.onda.seaglass.core.Log
import com.onda.seaglass.core.Paths
import java.io.File

/**
 * Makes ONNX Runtime's Windows library loadable on a computer without the Microsoft Visual C++
 * runtime (a freshly installed Windows has none, and 1.5.0's karaoke failed there with
 * "UnsatisfiedLinkError … onnxruntime.dll": a dependent library not found). ONNX Runtime's jar
 * unpacks its library into a temporary folder alone; here it is put in a folder of its own beside
 * the runtime's DLLs that the JavaCPP jar (FFmpeg's) carries, so Windows finds them next to it, and
 * those are also loaded by their full path first (a library already loaded by name is what an import
 * of that name gets). ONNX Runtime is told the folder with its `onnxruntime.native.path`.
 * Must run before the first use of ONNX Runtime: its Java side can't be loaded twice.
 */
object OrtNative {
    private const val ORT = "ai/onnxruntime/native/win-x64/"
    private const val VC = "org/bytedeco/javacpp/windows-x86_64/"
    private val ortLibraries = listOf("onnxruntime.dll", "onnxruntime4j_jni.dll")
    /** In the order they depend on each other. */
    private val runtime = listOf("vcruntime140.dll", "vcruntime140_1.dll", "msvcp140.dll", "msvcp140_1.dll", "concrt140.dll", "vcomp140.dll")

    @Volatile private var prepared = false

    @Synchronized
    fun prepare() {
        if (prepared || !WindowsIntegration.isWindows) return
        prepared = true
        runCatching {
            val dir = File(Paths.local, "Karaoke/native").apply { mkdirs() }
            val loader = OrtNative::class.java.classLoader
            fun copy(resource: String, name: String): Boolean {
                val input = loader.getResourceAsStream(resource + name) ?: return false
                val target = File(dir, name)
                input.use { source ->
                    val bytes = source.readBytes()
                    // Kept as it is when it's the same (the file may be in use by the running app).
                    if (target.length() != bytes.size.toLong()) target.writeBytes(bytes)
                }
                return true
            }
            val missing = ortLibraries.filterNot { copy(ORT, it) }
            check(missing.isEmpty()) { "ONNX Runtime's libraries aren't in the app: $missing" }
            val carried = runtime.filter { copy(VC, it) }
            for (name in carried) runCatching { System.load(File(dir, name).absolutePath) }
                .onFailure { Log.warn("Karaoke: $name couldn't be loaded", it) }
            System.setProperty("onnxruntime.native.path", dir.absolutePath)
            Log.info("Karaoke: ONNX Runtime is loaded from ${dir.name} with ${carried.size} runtime libraries")
        }.onFailure { Log.warn("Karaoke: ONNX Runtime's folder couldn't be prepared", it) }
    }
}
