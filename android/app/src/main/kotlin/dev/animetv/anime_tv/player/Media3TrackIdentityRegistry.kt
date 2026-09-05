package dev.animetv.anime_tv.player

/**
 * Request-local structural identities, retained through empty preparation
 * events and same-source decoder recreation. No ID is recycled until a new
 * open, even when the bounded cache evicts a long-disappeared manifest group.
 */
internal class Media3TrackIdentityRegistry<K : Any>(private val capacity: Int = 256) {
    init { require(capacity in 1..256) }
    private val ids = LinkedHashMap<K, Int>(capacity, 0.75f, true)
    private var nextId = 0
    val size: Int get() = ids.size

    fun idFor(identity: K): Int {
        ids[identity]?.let { return it }
        val id = nextId++
        ids[identity] = id
        if (ids.size > capacity) ids.remove(ids.keys.first())
        return id
    }

    fun clear() { ids.clear(); nextId = 0 }
}
