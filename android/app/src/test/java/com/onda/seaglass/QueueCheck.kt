package com.onda.seaglass

import com.onda.seaglass.playback.QueueOrder
import org.junit.Assert.assertEquals
import org.junit.Test

/** The queue's order after shuffle is turned off: the original order, with songs added meanwhile after it. */
class QueueCheck {
    @Test
    fun putsBackTheOriginalOrder() {
        val original = listOf("a", "b", "c", "d")
        // Shuffled, one played ("b"), one added while shuffled ("x"), and a song twice ("c").
        val upcoming = listOf("d", "x", "a", "c")
        assertEquals(listOf("a", "c", "d", "x"), QueueOrder.restoring(original, upcoming) { it })
        assertEquals(listOf("c", "c"), QueueOrder.restoring(listOf("c", "b", "c"), listOf("c", "c")) { it })
    }
}
