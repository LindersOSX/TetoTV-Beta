package dev.animetv.anime_tv.aniyomi

import android.os.IBinder
import android.os.Parcel
import org.json.JSONObject

/** Deliberately not a generic invocation, file, intent, or player-control interface. */
internal object AniyomiWire {
    const val DESCRIPTOR = "dev.animetv.anime_tv.aniyomi.worker.v1"
    const val CALLBACK_DESCRIPTOR = "dev.animetv.anime_tv.aniyomi.callback.v1"
    const val HELLO = IBinder.FIRST_CALL_TRANSACTION
    const val EXECUTE = IBinder.FIRST_CALL_TRANSACTION + 1
    const val CANCEL = IBinder.FIRST_CALL_TRANSACTION + 2
    const val COMPLETE = IBinder.FIRST_CALL_TRANSACTION
    const val HTTP = IBinder.FIRST_CALL_TRANSACTION + 1

    fun error(code: String): JSONObject = JSONObject().put("ok", false).put("error", code)

    fun checkParcel(data: Parcel, descriptor: String, maximum: Int = AniyomiPolicy.MAX_REQUEST_BYTES) {
        // Parcel strings are UTF-16 even though the protocol's text budgets use UTF-8.
        require(data.dataSize() <= maximum * 2 + 8192) { "parcel_too_large" }
        data.enforceInterface(descriptor)
    }

    fun readJson(data: Parcel, maximum: Int): JSONObject = JSONObject(
        AniyomiPolicy.boundedJsonText(data.readString() ?: throw IllegalArgumentException("missing_payload"), maximum),
    )

    fun call(remote: IBinder, code: Int, write: (Parcel) -> Unit): Parcel {
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        try {
            data.writeInterfaceToken(DESCRIPTOR)
            write(data)
            check(remote.transact(code, data, reply, 0)) { "worker_protocol_unavailable" }
            reply.readException()
            return reply
        } catch (error: Throwable) {
            reply.recycle()
            throw error
        } finally {
            data.recycle()
        }
    }
}
