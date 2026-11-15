package com.onda.seaglass.core

import java.util.Locale

/**
 * The app's translations. Like the iPhone and Android apps, the code is written in Italian and every
 * key is the Italian text: the tables are the iPhone app's own `Localizable.strings` (copied in at
 * build time), plus a few Windows-only lines in `src/main/l10n-windows`. Unsupported languages get
 * English. The language is Windows's, unless Settings chooses another (`Prefs.language`).
 */
object L10n {
    val supported = listOf("it", "en", "fr", "es", "de", "pt", "zh-Hans", "ja", "ru", "tr", "ar")

    @Volatile private var table: Map<String, String> = emptyMap()
    @Volatile var locale: Locale = Locale.getDefault()
        private set
    @Volatile var language: String = "it"
        private set

    /** The system's language as one of ours. */
    fun systemLanguage(): String {
        val system = Locale.getDefault()
        val code = when (system.language) {
            "zh" -> "zh-Hans"
            else -> system.language
        }
        return if (code in supported) code else "en"
    }

    /** [choice] is a language code, or null for the system's. */
    fun load(choice: String?) {
        val chosen = choice?.takeIf { it in supported } ?: systemLanguage()
        language = chosen
        locale = if (choice == null) Locale.getDefault() else Locale.forLanguageTag(if (chosen == "zh-Hans") "zh-CN" else chosen)
        table = if (chosen == "it") emptyMap() else parse(read("l10n/$chosen.strings")) + parse(read("l10n-windows/$chosen.strings"))
    }

    val isRightToLeft: Boolean get() = language == "ar"

    private fun read(path: String): String =
        runCatching { L10n::class.java.classLoader.getResourceAsStream(path)?.bufferedReader()?.use { it.readText() } }
            .getOrNull().orEmpty()

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
