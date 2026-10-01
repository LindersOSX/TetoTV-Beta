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

    /** A stale timeout may release its own operation, never a newer retry. */
    fun takeIf(candidate: T): T? = synchronized(lock) {
        if (operation !== candidate) null else operation.also { operation = null }
    }

    /** Match an identity carried back from an asynchronous native callback. */
    fun takeMatching(matches: (T) -> Boolean): T? = synchronized(lock) {
        val current = operation
        if (current == null || !matches(current)) null
        else current.also { operation = null }
    }
}
