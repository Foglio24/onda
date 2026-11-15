package com.onda.seaglass.core

import java.util.Locale

/** Italian strings are the localization keys (as on iPhone/Android). Stub until .strings land. */
object L10n {
    val locale: Locale get() = Locale.getDefault()

    fun tr(key: String, vararg args: Any?): String {
        if (args.isEmpty()) return key
        var out = key
        // Replace printf-style tokens in order: %@, %lld, %d, %s, %f
        val tokens = listOf("%@", "%lld", "%d", "%s", "%f", "%.1f", "%.0f")
        var i = 0
        for (arg in args) {
            val token = tokens.firstOrNull { out.contains(it) } ?: break
            out = out.replaceFirst(token, arg?.toString().orEmpty())
            i++
        }
        return out
    }
}

fun tr(key: String, vararg args: Any?): String = L10n.tr(key, *args)
