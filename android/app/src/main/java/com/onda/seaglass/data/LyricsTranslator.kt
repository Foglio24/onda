package com.onda.seaglass.data

import com.google.android.gms.tasks.Task
import com.google.mlkit.common.model.DownloadConditions
import com.google.mlkit.nl.languageid.LanguageIdentification
import com.google.mlkit.nl.translate.TranslateLanguage
import com.google.mlkit.nl.translate.Translation
import com.google.mlkit.nl.translate.TranslatorOptions
import com.onda.seaglass.core.L10n
import com.onda.seaglass.core.tr
import kotlinx.coroutines.suspendCancellableCoroutine
import java.util.Locale
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Lyrics translated on the phone (Google's ML Kit), as the iPhone translates them with Apple's:
 * the song's language is recognised, the language's model is downloaded once (about 30 MB), and
 * from then on it works offline.
 */
object LyricsTranslator {
    /** The languages offered as "Traduci in", as on the iPhone. */
    val languages = listOf(
        "it", "en", "es", "fr", "de", "pt", "nl", "pl", "ru", "uk", "tr",
        "ar", "hi", "id", "th", "vi", "ja", "ko", "zh",
    )

    fun languageName(tag: String): String {
        val locale = Locale.forLanguageTag(tag)
        return locale.getDisplayLanguage(L10n.locale).replaceFirstChar { it.titlecase(L10n.locale) }
    }

    /** The language lyrics are translated into: the one chosen, or the app's. */
    fun target(): String = Prefs.translationTarget.value.ifEmpty {
        when (val app = L10n.language) {
            "zh-Hans" -> "zh"
            else -> app
        }
    }

    sealed interface Progress {
        data object Translating : Progress
        data object DownloadingModel : Progress
    }

    class TranslationException(message: String) : Exception(message)

    /** [lines] in the target language, one for each (empty lines stay empty). */
    suspend fun translate(lines: List<String>, progress: (Progress) -> Unit): List<String> {
        val text = lines.filter { it.isNotBlank() }.joinToString("\n")
        val identified = LanguageIdentification.getClient().identifyLanguage(text).await()
        if (identified == "und") throw TranslationException(tr("Lingua del testo non riconosciuta"))
        val target = target()
        val sourceCode = TranslateLanguage.fromLanguageTag(identified)
            ?: throw TranslationException(tr("Traduzione da %@ non disponibile", languageName(identified)))
        val targetCode = TranslateLanguage.fromLanguageTag(target)
            ?: throw TranslationException(tr("Traduzione non disponibile"))
        if (sourceCode == targetCode) throw TranslationException(tr("Il testo è già in %@", languageName(target)))
        val translator = Translation.getClient(
            TranslatorOptions.Builder().setSourceLanguage(sourceCode).setTargetLanguage(targetCode).build(),
        )
        try {
            progress(Progress.DownloadingModel)
            translator.downloadModelIfNeeded(DownloadConditions.Builder().build()).await()
            progress(Progress.Translating)
            return lines.map { line -> if (line.isBlank()) "" else translator.translate(line).await() }
        } catch (e: TranslationException) {
            throw e
        } catch (e: Exception) {
            throw TranslationException(tr("Traduzione non riuscita: %@", e.localizedMessage ?: e.javaClass.simpleName))
        } finally {
            translator.close()
        }
    }

    private suspend fun <T> Task<T>.await(): T = suspendCancellableCoroutine { continuation ->
        addOnSuccessListener { continuation.resume(it) }
        addOnFailureListener { continuation.resumeWithException(it) }
        addOnCanceledListener { continuation.cancel() }
    }
}
