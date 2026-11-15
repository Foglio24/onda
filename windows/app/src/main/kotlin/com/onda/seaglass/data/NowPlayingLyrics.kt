package com.onda.seaglass.data

import com.onda.seaglass.audio.Player
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

/** The playing song's lyrics (LRCLIB), fetched when the song changes: one request per song, none per tick. */
object NowPlayingLyrics {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val _state = MutableStateFlow<LyricsState>(LyricsState.Unavailable)
    val state: StateFlow<LyricsState> = _state
    private var job: Job? = null

    fun init() {
        scope.launch {
            Player.state.map { it.current }.distinctUntilChanged { a, b -> a?.videoId == b?.videoId }.collect { track ->
                job?.cancel()
                if (track == null) {
                    _state.value = LyricsState.Unavailable
                    return@collect
                }
                _state.value = LyricsState.Loading
                job = scope.launch {
                    _state.value = runCatching { Lyrics.lyrics(track) }.getOrDefault(LyricsState.Unavailable)
                }
            }
        }
    }
}
