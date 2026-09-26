package com.litter.android.ui.home

import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.flow.distinctUntilChanged

/*
 * Session list virtualization rules, shared with iOS (keep the numbers in sync):
 *
 *  - Lazy list (LazyColumn / LazyVStack) with stable keys "serverId/threadId"
 *    and a contentType per row kind, so rows are reused and never re-keyed.
 *  - Row height ~62dp (title + one meta line); rows reserve it from the first
 *    frame so cached and live rows have the same geometry.
 *  - Only rows inside the viewport plus PREFETCH_ROWS (10) beyond it hydrate
 *    their thread (resume + initial turns). Off-screen rows show the summary.
 *  - At most MAX_CONCURRENT_HYDRATIONS (4) hydrations run at once.
 *  - Lists render PAGE_SIZE (50) rows at a time; the next page is appended when
 *    the last visible row comes within PREFETCH_ROWS of the rendered end, so
 *    1000+ sessions never compose or diff at once.
 *  - Updates are in place: no item placement animation, no empty state while
 *    the session list is still unknown.
 */
object HomeListVirtualization {
    val ROW_HEIGHT = 62.dp
    const val PREFETCH_ROWS = 10
    const val MAX_CONCURRENT_HYDRATIONS = 4
    const val PAGE_SIZE = 50

    /** Indices eligible for hydration: the viewport plus [PREFETCH_ROWS] after it. */
    fun hydrationWindow(firstVisible: Int, lastVisible: Int, count: Int): IntRange {
        if (count <= 0) return IntRange.EMPTY
        val start = firstVisible.coerceIn(0, count - 1)
        val end = (maxOf(lastVisible, firstVisible) + PREFETCH_ROWS).coerceIn(start, count - 1)
        return start..end
    }

    /**
     * Number of rows to render. Grows by [PAGE_SIZE] once the last visible
     * row is within [PREFETCH_ROWS] of the current limit; never shrinks below
     * one page, never exceeds [total].
     */
    fun renderedCount(currentLimit: Int, lastVisible: Int, total: Int): Int {
        var limit = maxOf(currentLimit, PAGE_SIZE)
        if (lastVisible >= limit - PREFETCH_ROWS) {
            limit += PAGE_SIZE
        }
        return minOf(limit, total)
    }
}

/**
 * Remembers the paged row limit for a list driven by [state]. [resetKey]
 * returns the list to its first page (e.g. a new search query).
 */
@Composable
fun rememberPagedLimit(state: LazyListState, total: Int, resetKey: Any?): Int {
    var limit by rememberSaveable(resetKey) { mutableIntStateOf(HomeListVirtualization.PAGE_SIZE) }
    LaunchedEffect(state, resetKey) {
        snapshotFlow { state.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0 }
            .distinctUntilChanged()
            .collect { last ->
                val next = HomeListVirtualization.renderedCount(limit, last, Int.MAX_VALUE)
                if (next != limit) limit = next
            }
    }
    return minOf(limit, total)
}

/** First/last visible item indices, recomposing only when they change. */
@Composable
fun rememberVisibleRange(state: LazyListState): IntRange {
    var first by remember { mutableIntStateOf(0) }
    var last by remember { mutableIntStateOf(HomeListVirtualization.PREFETCH_ROWS) }
    LaunchedEffect(state) {
        snapshotFlow {
            val items = state.layoutInfo.visibleItemsInfo
            (items.firstOrNull()?.index ?: 0) to (items.lastOrNull()?.index ?: 0)
        }
            .distinctUntilChanged()
            .collect { (f, l) ->
                first = f
                last = l
            }
    }
    return first..last
}
