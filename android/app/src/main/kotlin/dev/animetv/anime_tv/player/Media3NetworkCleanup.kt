package dev.animetv.anime_tv.player

import java.util.concurrent.Executor
import java.util.concurrent.Executors
import okhttp3.OkHttpClient

/** TLS close/cancel can perform network I/O, even when no request is loading. */
internal object Media3NetworkCleanup {
    private val executor = Executors.newSingleThreadExecutor { task ->
        Thread(task, "TetoTV-media3-network-cleanup").apply { isDaemon = true }
    }

    fun release(client: OkHttpClient) = enqueue(
        executor,
        { client.dispatcher.cancelAll() },
        { client.connectionPool.evictAll() },
        { client.dispatcher.executorService.shutdown() },
    )

    internal fun enqueue(executor: Executor, cancel: () -> Unit, evict: () -> Unit, shutdown: () -> Unit) {
        executor.execute {
            // Network resources are independent from ExoPlayer ownership.
            // Failure of any one step must not skip its siblings or strand
            // decoder release. No untrusted exception text is logged here.
            runCatching(cancel)
            runCatching(evict)
            runCatching(shutdown)
        }
    }
}
