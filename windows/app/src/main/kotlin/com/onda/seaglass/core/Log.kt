package com.onda.seaglass.core

import java.io.File
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter
import java.util.concurrent.Executors

/**
 * A short diary of what the app did (songs that couldn't play, AutoMix's decisions), in
 * %LOCALAPPDATA%\Seaglass\Logs, for the user to send when something goes wrong. Written on its own
 * thread, never from the audio thread; about 2 MB at most (one older file kept). Never holds tokens,
 * stream addresses or anything private: only what the messages below say.
 */
object Log {
    private const val LIMIT = 1_000_000L
    private val writer = Executors.newSingleThreadExecutor { Thread(it, "seaglass-log").apply { isDaemon = true } }
    private val time = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss")
    val file: File by lazy { File(Paths.logs, "seaglass.log") }

    fun info(message: String) = write("info", message, null)

    fun warn(message: String, error: Throwable? = null) = write("warn", message, error)

    private fun write(level: String, message: String, error: Throwable?) {
        var line = LocalDateTime.now().format(time) + " " + level + " " + message
        // The error's kind and message only: its stack would say nothing to the user.
        if (error != null) line += " (" + error.javaClass.simpleName + ": " + error.message.orEmpty().take(200) + ")"
        // Addresses (a stream's carries its signature) are left out, whatever a message said.
        line = line.replace(Regex("""https?://\S+"""), "<address>").replace('\n', ' ') + "\n"
        writer.execute {
            runCatching {
                if (file.length() > LIMIT) {
                    val older = File(file.parentFile, "seaglass.1.log")
                    older.delete()
                    file.renameTo(older)
                }
                file.appendText(line)
            }
        }
    }
}
