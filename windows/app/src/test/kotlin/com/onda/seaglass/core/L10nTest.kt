package com.onda.seaglass.core

import java.io.File
import kotlin.test.Test
import kotlin.test.assertTrue

/**
 * Every text the app shows has a translation in every language, as the iPhone app's
 * check_localization.py checks: in the iPhone's tables or in src/main/l10n-windows, with the same
 * format specifiers as its Italian key.
 */
class L10nTest {
    private val languages = listOf("en", "fr", "es", "de", "pt", "zh-Hans", "ja", "ru", "tr", "ar")
    private val specifier = Regex("""%(\d+\$)?(@|lld|ld|d|s)""")

    private fun keysInCode(): Set<String> {
        val keys = HashSet<String>()
        val call = Regex("""\btr\(\s*"((?:[^"\\]|\\.)*)"""")
        val conditional = Regex("""\btr\(if \([^)]*\) "((?:[^"\\]|\\.)*)" else "((?:[^"\\]|\\.)*)"\)""")
        File("src/main/kotlin").walkTopDown().filter { it.extension == "kt" }.forEach { file ->
            val text = file.readText()
            call.findAll(text).forEach { keys += it.groupValues[1] }
            conditional.findAll(text).forEach { keys += it.groupValues[1]; keys += it.groupValues[2] }
        }
        return keys.map { it.replace("\\\"", "\"").replace(Regex("""\\u([0-9a-fA-F]{4})""")) { m -> m.groupValues[1].toInt(16).toChar().toString() } }
            // Keys built at run time ("%@" alone, names) aren't text to translate.
            .filter { it.any(Char::isLetter) }.toSet()
    }

    @Test
    fun everyTextIsTranslated() {
        val keys = keysInCode()
        assertTrue(keys.size > 100, "found the app's texts: ${keys.size}")
        val problems = mutableListOf<String>()
        for (language in languages) {
            val table = L10n.parse(File("../../Seaglass/Resources/$language.lproj/Localizable.strings").readText()) +
                L10n.parse(File("src/main/l10n-windows/$language.strings").readText())
            for (key in keys) {
                val value = table[key]
                if (value == null) {
                    problems += "$language: \"$key\" has no translation"
                } else if (specifier.findAll(key).map { it.value }.toList() != specifier.findAll(value).map { it.value }.toList()) {
                    problems += "$language: \"$key\" → \"$value\" has other format specifiers"
                }
            }
        }
        assertTrue(problems.isEmpty(), problems.take(30).joinToString("\n"))
    }
}
