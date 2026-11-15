package com.onda.seaglass.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.onda.seaglass.data.Lyrics
import com.onda.seaglass.data.LyricsState
import com.onda.seaglass.model.Track
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

@Composable
fun LyricsPanel(track: Track?, positionSec: Double) {
    var state by remember(track?.videoId) { mutableStateOf<LyricsState>(LyricsState.Loading) }
    LaunchedEffect(track?.videoId) {
        state = LyricsState.Loading
        val t = track ?: return@LaunchedEffect
        state = withContext(Dispatchers.IO) { Lyrics.lyrics(t) }
    }
    Column(Modifier.fillMaxWidth()) {
        Text("Testo", fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(8.dp))
        when (val s = state) {
            LyricsState.Loading -> Text("Caricamento…", color = MaterialTheme.colorScheme.onSurfaceVariant)
            LyricsState.Unavailable -> Text("Nessun testo trovato.", color = MaterialTheme.colorScheme.onSurfaceVariant)
            is LyricsState.Plain -> Text(s.text)
            is LyricsState.Synced -> {
                val listState = rememberLazyListState()
                val active = s.lines.indexOfLast { it.time <= positionSec }.coerceAtLeast(0)
                LaunchedEffect(active) {
                    runCatching { listState.animateScrollToItem(active.coerceAtMost(s.lines.lastIndex)) }
                }
                LazyColumn(state = listState, modifier = Modifier.height(220.dp)) {
                    items(s.lines) { line ->
                        val current = line.index == active
                        Text(
                            line.text.ifEmpty { " " },
                            fontWeight = if (current) FontWeight.Bold else FontWeight.Normal,
                            fontSize = if (current) 16.sp else 14.sp,
                            color = if (current) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Spacer(Modifier.height(6.dp))
                    }
                }
            }
        }
    }
}
