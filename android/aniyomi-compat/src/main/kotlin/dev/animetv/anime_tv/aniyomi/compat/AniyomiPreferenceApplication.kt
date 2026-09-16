package dev.animetv.anime_tv.aniyomi.compat

import android.app.Application
import android.content.Context
import android.content.SharedPreferences

/**
 * A deliberately base-less [Application] exposed to extension code through Injekt.
 *
 * Current extension helpers ask Injekt for an Application solely to obtain a
 * source-scoped SharedPreferences instance. Passing the worker's real Application
 * would expose its files, package APIs and system services. This object implements
 * only bounded, process-memory preferences; inherited ContextWrapper operations
 * have no base context and therefore cannot reach the host application.
 */
internal class AniyomiPreferenceApplication : Application() {
    private val stores = linkedMapOf<String, AniyomiMemoryPreferences>()

    override fun getApplicationContext(): Context = this

    @Synchronized
    override fun getSharedPreferences(name: String, mode: Int): SharedPreferences {
        require(mode == Context.MODE_PRIVATE) { "Only private provider preferences are supported" }
        require(name.length in 1..MAX_STORE_NAME && STORE_NAME.matches(name)) {
            "Invalid provider preference store"
        }
        return stores.getOrPut(name) {
            require(stores.size < MAX_STORES) { "Too many provider preference stores" }
            AniyomiMemoryPreferences()
        }
    }

    private companion object {
        const val MAX_STORES = 64
        const val MAX_STORE_NAME = 160
        val STORE_NAME = Regex("[A-Za-z0-9_.:-]+")
    }
}

/** Small defensive SharedPreferences implementation scoped to one worker invocation. */
private class AniyomiMemoryPreferences : SharedPreferences {
    private val values = linkedMapOf<String, Any>()
    private val listeners = linkedSetOf<SharedPreferences.OnSharedPreferenceChangeListener>()

    @Synchronized
    override fun getAll(): Map<String, *> = values.mapValues { (_, value) -> copyValue(value) }

    @Synchronized
    override fun getString(key: String, defValue: String?): String? = value(key, defValue)

    @Synchronized
    override fun getStringSet(key: String, defValues: Set<String>?): Set<String>? =
        value<Set<String>?>(key, defValues)?.toSet()

    @Synchronized
    override fun getInt(key: String, defValue: Int): Int = value(key, defValue)

    @Synchronized
    override fun getLong(key: String, defValue: Long): Long = value(key, defValue)

    @Synchronized
    override fun getFloat(key: String, defValue: Float): Float = value(key, defValue)

    @Synchronized
    override fun getBoolean(key: String, defValue: Boolean): Boolean = value(key, defValue)

    @Synchronized
    override fun contains(key: String): Boolean = values.containsKey(validKey(key))

    override fun edit(): SharedPreferences.Editor = Editor()

    @Synchronized
    override fun registerOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener) {
        listeners.add(listener)
    }

    @Synchronized
    override fun unregisterOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener) {
        listeners.remove(listener)
    }

    @Suppress("UNCHECKED_CAST")
    private fun <T> value(key: String, default: T): T = (values[validKey(key)] ?: default) as T

    private inner class Editor : SharedPreferences.Editor {
        private val changes = linkedMapOf<String, Any?>()
        private var clear = false

        override fun putString(key: String, value: String?): SharedPreferences.Editor = put(key, value?.let(::validText))

        override fun putStringSet(key: String, values: Set<String>?): SharedPreferences.Editor = put(
            key,
            values?.also { require(it.size <= MAX_SET_ITEMS) { "Provider preference set is too large" } }
                ?.map(::validText)?.toSet(),
        )

        override fun putInt(key: String, value: Int): SharedPreferences.Editor = put(key, value)
        override fun putLong(key: String, value: Long): SharedPreferences.Editor = put(key, value)
        override fun putFloat(key: String, value: Float): SharedPreferences.Editor = put(key, value)
        override fun putBoolean(key: String, value: Boolean): SharedPreferences.Editor = put(key, value)
        override fun remove(key: String): SharedPreferences.Editor = put(key, null)
        override fun clear(): SharedPreferences.Editor = apply { clear = true }
        override fun commit(): Boolean { applyChanges(); return true }
        override fun apply() = applyChanges()

        private fun put(key: String, value: Any?): SharedPreferences.Editor = apply {
            changes[validKey(key)] = value
        }

        private fun applyChanges() {
            val changed: List<String>
            val callbacks: List<SharedPreferences.OnSharedPreferenceChangeListener>
            synchronized(this@AniyomiMemoryPreferences) {
                val changedKeys = linkedSetOf<String>()
                if (clear) {
                    changedKeys.addAll(values.keys)
                    values.clear()
                }
                for ((key, value) in changes) {
                    if (value == null) values.remove(key) else values[key] = copyValue(value)
                    changedKeys.add(key)
                }
                require(values.size <= MAX_ENTRIES) { "Too many provider preference entries" }
                changed = changedKeys.toList()
                callbacks = listeners.toList()
            }
            changed.forEach { key -> callbacks.forEach { it.onSharedPreferenceChanged(this@AniyomiMemoryPreferences, key) } }
        }
    }

    private companion object {
        const val MAX_ENTRIES = 256
        const val MAX_KEY_BYTES = 512
        const val MAX_TEXT_BYTES = 16 * 1024
        const val MAX_SET_ITEMS = 128

        fun validKey(key: String): String = key.also {
            require(it.isNotEmpty() && it.toByteArray(Charsets.UTF_8).size <= MAX_KEY_BYTES && '\u0000' !in it) {
                "Invalid provider preference key"
            }
        }

        fun validText(value: String): String = value.also {
            require(it.toByteArray(Charsets.UTF_8).size <= MAX_TEXT_BYTES && '\u0000' !in it) {
                "Provider preference value is too large"
            }
        }

        fun copyValue(value: Any): Any = if (value is Set<*>) value.toSet() else value
    }
}
