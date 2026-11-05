package com.onda.seaglass.core

import android.content.Context
import java.util.Locale

/**
 * The app's translations. Like the iPhone app, the code is written in Italian and every key is the
 * Italian text: the tables are the iPhone app's own `Localizable.strings` (copied in at build time),
 * plus a few Android-only lines in `assets/l10n-android`. Unsupported languages get English.
 */
object L10n {
    private val supported = setOf("it", "en", "fr", "es", "de", "pt", "zh-Hans", "ja", "ru", "tr", "ar")

    @Volatile private var table: Map<String, String> = emptyMap()
    @Volatile var locale: Locale = Locale.getDefault()
        private set
    @Volatile var language: String = "it"
        private set

    fun load(context: Context) {
        val current = context.resources.configuration.locales[0] ?: Locale.getDefault()
        val code = when (current.language) {
            "zh" -> "zh-Hans"
            "iw", "he" -> "en"
            else -> current.language
        }
        val chosen = if (code in supported) code else "en"
        if (chosen == language && table.isNotEmpty() && current == locale) return
        locale = current
        language = chosen
        table = if (chosen == "it") emptyMap() else {
            parse(read(context, "l10n/$chosen.strings")) + parse(read(context, "l10n-android/$chosen.strings"))
        }
    }

    private fun read(context: Context, path: String): String =
        runCatching { context.assets.open(path).bufferedReader().use { it.readText() } }.getOrDefault("")

    /** The translation of [key] (Italian text in the iPhone app's format: `%@`, `%lld`). */
    fun tr(key: String, vararg args: Any?): String {
        val text = convert(table[key] ?: key)
        return if (args.isEmpty()) text else runCatching { String.format(locale, text, *args) }.getOrDefault(text)
    }

    private val specifier = Regex("""%(\d+\$)?(@|lld|ld|llu|lu)""")

    /** iOS format specifiers to Java ones: `%@` → `%s`, `%lld` → `%d`, `%1$@` → `%1$s`. */
    private fun convert(text: String): String {
        if ('%' !in text) return text
        return specifier.replace(text) { match ->
            val position = match.groupValues[1]
            if (match.groupValues[2] == "@") "%${position}s" else "%${position}d"
        }
    }

    /** Reads `"key" = "value";` lines, skipping comments. */
    fun parse(source: String): Map<String, String> {
        val result = HashMap<String, String>()
        var i = 0
        val n = source.length
        fun skipSpaceAndComments() {
            while (i < n) {
                when {
                    source[i].isWhitespace() -> i++
                    source.startsWith("/*", i) -> i = source.indexOf("*/", i + 2).let { if (it < 0) n else it + 2 }
                    source.startsWith("//", i) -> i = source.indexOf('\n', i).let { if (it < 0) n else it + 1 }
                    else -> return
                }
            }
        }
        fun quoted(): String? {
            if (i >= n || source[i] != '"') return null
            i++
            val out = StringBuilder()
            while (i < n && source[i] != '"') {
                val c = source[i]
                if (c == '\\' && i + 1 < n) {
                    i++
                    when (val e = source[i]) {
                        'n' -> out.append('\n')
                        't' -> out.append('\t')
                        'r' -> out.append('\r')
                        'U', 'u' -> {
                            val hex = source.substring(i + 1, minOf(n, i + 5))
                            hex.toIntOrNull(16)?.let { out.append(it.toChar()); i += 4 } ?: out.append(e)
                        }
                        else -> out.append(e)
                    }
                } else {
                    out.append(c)
                }
                i++
            }
            i++
            return out.toString()
        }
        while (i < n) {
            skipSpaceAndComments()
            val key = quoted() ?: break
            skipSpaceAndComments()
            if (i < n && source[i] == '=') i++
            skipSpaceAndComments()
            val value = quoted() ?: break
            skipSpaceAndComments()
            if (i < n && source[i] == ';') i++
            result[key] = value
        }
        return result
    }
}

/** Shorthand used everywhere in the app. */
fun tr(key: String, vararg args: Any?): String = L10n.tr(key, *args)
