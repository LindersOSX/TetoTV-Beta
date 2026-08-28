package dev.animetv.anime_tv

/**
 * Atomic single-operation slot used at asynchronous platform boundaries.
 *
 * [take] clears before returning, so cancellation releases the slot before a
 * retry can attempt to claim it.
 */
internal class PendingOperationSlot<T : Any> {
    private val lock = Any()
    private var operation: T? = null

    fun trySet(candidate: T): Boolean = synchronized(lock) {
        if (operation != null) {
            false
        } else {
            operation = candidate
            true
        }
    }

    fun take(): T? = synchronized(lock) {
        operation.also { operation = null }
    }
}
