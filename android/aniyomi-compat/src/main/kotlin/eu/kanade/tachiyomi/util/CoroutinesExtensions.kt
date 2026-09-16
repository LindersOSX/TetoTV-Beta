// Adapted from Aniyomi extensions-lib 16; Apache-2.0.
package eu.kanade.tachiyomi.util

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext

@Deprecated("Source developers should define their own extension functions for more flexibility")
suspend inline fun <A, B> Iterable<A>.parallelMap(crossinline f: suspend (A) -> B): List<B> =
    withContext(Dispatchers.IO) { map { async { f(it) } }.awaitAll() }

@Deprecated("Source developers should define their own extension functions for more flexibility")
inline fun <A, B> Iterable<A>.parallelMapBlocking(crossinline f: suspend (A) -> B): List<B> =
    runBlocking { parallelMap(f) }

@Deprecated("Source developers should define their own extension functions for more flexibility")
suspend inline fun <A, B> Iterable<A>.parallelMapNotNull(crossinline f: suspend (A) -> B?): List<B> =
    withContext(Dispatchers.IO) { map { async { f(it) } }.awaitAll().filterNotNull() }

@Deprecated("Source developers should define their own extension functions for more flexibility")
inline fun <A, B> Iterable<A>.parallelMapNotNullBlocking(crossinline f: suspend (A) -> B?): List<B> =
    runBlocking { parallelMapNotNull(f) }

@Deprecated("Source developers should define their own extension functions for more flexibility")
suspend inline fun <A, B> Iterable<A>.parallelFlatMap(crossinline f: suspend (A) -> Iterable<B>): List<B> =
    withContext(Dispatchers.IO) { map { async { f(it) } }.awaitAll().flatten() }

@Deprecated("Source developers should define their own extension functions for more flexibility")
inline fun <A, B> Iterable<A>.parallelFlatMapBlocking(crossinline f: suspend (A) -> Iterable<B>): List<B> =
    runBlocking { parallelFlatMap(f) }

@Deprecated("Source developers should define their own extension functions for more flexibility")
suspend inline fun <A, B> Iterable<A>.parallelCatchingFlatMap(crossinline f: suspend (A) -> Iterable<B>): List<B> =
    withContext(Dispatchers.IO) {
        map {
            async {
                try {
                    f(it)
                } catch (_: Throwable) {
                    emptyList()
                }
            }
        }.awaitAll().flatten()
    }

@Deprecated("Source developers should define their own extension functions for more flexibility")
inline fun <A, B> Iterable<A>.parallelCatchingFlatMapBlocking(crossinline f: suspend (A) -> Iterable<B>): List<B> =
    runBlocking { parallelCatchingFlatMap(f) }
