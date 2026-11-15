package com.onda.seaglass.data

import com.onda.seaglass.account.Account
import com.onda.seaglass.core.L10n
import com.onda.seaglass.core.Log
import com.onda.seaglass.core.Prefs
import com.onda.seaglass.core.tr
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap

/**
 * Lyrics translated, as on the iPhone (Premium): Windows has no translator of its own, so the
 * Seaglass account service translates them (its language recognised there), line by line. A
 * song's translation is kept for as long as the app runs.
 */
object LyricsTranslator {
    /** The languages offered as "Traduci in", as on the iPhone. */
    val languages = listOf("it", "en", "es", "fr", "de", "pt", "nl", "pl", "ru", "uk", "tr", "ar", "hi", "id", "th", "vi", "ja", "ko", "zh")

    fun languageName(tag: String): String =
        Locale.forLanguageTag(tag).getDisplayLanguage(L10n.locale).replaceFirstChar { it.titlecase(L10n.locale) }

    /** The language lyrics are translated into: the one chosen, or the app's. */
    fun target(): String = Prefs.translationTarget.value.takeIf { it in languages } ?: when (val app = L10n.language) {
        "zh-Hans" -> "zh"
        else -> app.takeIf { it in languages } ?: "en"
    }

    /** What went wrong, said plainly; [signIn] and [premium] say what the user can do about it. */
    class TranslationException(message: String, val signIn: Boolean = false, val premium: Boolean = false) : Exception(message)

    private val cache = ConcurrentHashMap<String, List<String>>()

    /** [lines] of the song [id] in the target language, one for each (empty lines stay empty). */
    suspend fun translate(id: String, lines: List<String>): List<String> {
        val target = target()
        val key = "$id|$target"
        cache[key]?.let { return it }
        if (!Account.signedIn.value) throw TranslationException(tr("Accedi con il tuo account Seaglass per tradurre i testi."), signIn = true)
        val (status, answer) = try {
            withContext(Dispatchers.IO) { Account.translate(lines, target) }
        } catch (e: Exception) {
            Log.warn("Lyrics translation failed", e)
            throw TranslationException(tr("Traduzione non disponibile"))
        }
        when (status) {
            200 -> {
                val array = answer?.optJSONArray("lines")
                val translated = if (array != null && array.length() == lines.size) List(lines.size) { array.optString(it) } else null
                if (translated == null) throw TranslationException(tr("Traduzione non disponibile"))
                cache[key] = translated
                return translated
            }
            0, 401 -> throw TranslationException(tr("Accedi con il tuo account Seaglass per tradurre i testi."), signIn = true)
            403 -> throw TranslationException(tr("Traduzione non disponibile"), premium = true)
            409 -> throw TranslationException(tr("Il testo è già in %@", languageName(answer?.optString("source")?.takeIf { it.isNotEmpty() } ?: target)))
            422 -> throw TranslationException(tr("Lingua del testo non riconosciuta"))
            else -> {
                Log.warn("Lyrics translation: the service answered $status (${answer?.optString("error").orEmpty()})")
                throw TranslationException(tr("Traduzione non disponibile"))
            }
        }
    }
}
