package dev.animetv.anime_tv

import android.content.Context
import android.os.StatFs
import org.libtorrent4j.AlertListener
import org.libtorrent4j.Priority
import org.libtorrent4j.SessionManager
import org.libtorrent4j.SessionParams
import org.libtorrent4j.SettingsPack
import org.libtorrent4j.TorrentFlags
import org.libtorrent4j.TorrentHandle
import org.libtorrent4j.TorrentInfo
import org.libtorrent4j.alerts.AddTorrentAlert
import org.libtorrent4j.alerts.Alert
import org.libtorrent4j.alerts.AlertType
import org.libtorrent4j.swig.session_handle
import org.libtorrent4j.swig.settings_pack
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.File
import java.io.RandomAccessFile
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.charset.StandardCharsets
import java.security.SecureRandom
import java.util.Locale
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

internal data class DirectTorrentStartResult(
    val sessionId: String,
    val playbackUrl: String,
    val size: Long,
    val mimeType: String,
    val selectedBasename: String,
)

internal class DirectTorrentException(
    val code: String,
    safeMessage: String,
) : Exception(safeMessage)

internal enum class DirectTorrentEngineAcquireAction { START, RESUME }

/** Testable ownership state for the one process-lifetime native engine. */
internal class DirectTorrentEngineState {
    var started: Boolean = false
        private set
    var leased: Boolean = false
        private set
    var poisoned: Boolean = false
        private set

    fun beginAcquire(): DirectTorrentEngineAcquireAction {
        check(!poisoned) { "A poisoned direct torrent engine cannot be reused." }
        check(!leased) { "The direct torrent engine already has an active lease." }
        leased = true
        return if (started) {
            DirectTorrentEngineAcquireAction.RESUME
        } else {
            DirectTorrentEngineAcquireAction.START
        }
    }

    fun markStarted() {
        started = true
    }

    fun failAcquire() {
        leased = false
    }

    fun poison() {
        poisoned = true
    }

    fun release(): Boolean {
        if (!leased) return false
        leased = false
        return true
    }
}

/**
 * Keeps libtorrent4j's SessionManager alive for the Android process lifetime.
 *
 * Version 2.1.0-38 has upstream races in SessionManager.stop(), so ordinary
 * playback cleanup must never stop or reconstruct the alert loop. An idle
 * engine has no torrents/listeners, DHT is stopped, all peer transports are
 * disabled, and the session is paused. The next explicit lease reverses those
 * settings without invoking the unsafe stop path.
 */
internal object DirectTorrentEngine {
    private val session = SessionManager(false)
    private val state = DirectTorrentEngineState()
    private val monitor = Object()

    fun acquire(listener: AlertListener) {
        synchronized(monitor) {
            val deadline = System.nanoTime() +
                TimeUnit.SECONDS.toNanos(ENGINE_RELEASE_WAIT_SECONDS)
            while (state.leased && !state.poisoned) {
                val remaining = deadline - System.nanoTime()
                if (remaining <= 0L) {
                    throw DirectTorrentException(
                        "DIRECT_TORRENT_BUSY",
                        "The previous direct torrent session is still closing.",
                    )
                }
                monitor.wait(
                    TimeUnit.NANOSECONDS.toMillis(remaining).coerceAtLeast(1L),
                )
            }
            if (state.poisoned) {
                throw DirectTorrentException(
                    "DIRECT_TORRENT_RESTART_REQUIRED",
                    "Direct torrent playback needs an app restart after an unsafe cleanup.",
                )
            }
            val action = state.beginAcquire()
            try {
                when (action) {
                    DirectTorrentEngineAcquireAction.START -> {
                        session.start(SessionParams(networkSettings(enabled = true)))
                        state.markStarted()
                    }
                    DirectTorrentEngineAcquireAction.RESUME -> Unit
                }
                session.applySettings(networkSettings(enabled = true))
                session.resume()
                if (!session.isDhtRunning) session.startDht()
                session.addListener(listener)
            } catch (error: Throwable) {
                if (session.isRunning) state.markStarted()
                state.failAcquire()
                idleSession()
                monitor.notifyAll()
                throw error
            }
        }
    }

    fun download(
        magnetUri: String,
        destination: File,
        flags: org.libtorrent4j.swig.torrent_flags_t,
    ) = synchronized(monitor) {
        check(state.leased)
        session.download(magnetUri, destination, flags)
    }

    fun remove(handle: TorrentHandle): Boolean = synchronized(monitor) {
        if (!state.leased) return@synchronized false
        runCatching {
            val deleteFlags = session_handle.delete_files.or_(session_handle.delete_partfile)
            session.remove(handle, deleteFlags)
            true
        }.getOrDefault(false)
    }

    fun release(listener: AlertListener) {
        synchronized(monitor) {
            if (!state.release()) return
            runCatching { session.removeListener(listener) }
            idleSession()
            monitor.notifyAll()
        }
    }

    fun poison() {
        synchronized(monitor) {
            state.poison()
            idleSession()
            monitor.notifyAll()
        }
    }

    private fun idleSession() {
        if (!state.started) return
        runCatching { session.stopDht() }
        runCatching { session.applySettings(networkSettings(enabled = false)) }
        runCatching { session.pause() }
    }

    private fun networkSettings(enabled: Boolean): SettingsPack = SettingsPack()
        .setBoolean(settings_pack.bool_types.enable_outgoing_utp.swigValue(), enabled)
        .setBoolean(settings_pack.bool_types.enable_incoming_utp.swigValue(), enabled)
        .setBoolean(settings_pack.bool_types.enable_outgoing_tcp.swigValue(), enabled)
        .setBoolean(settings_pack.bool_types.enable_incoming_tcp.swigValue(), enabled)
        .setBoolean(settings_pack.bool_types.enable_dht.swigValue(), enabled)
        // LAN discovery and automatic router mappings remain disabled even
        // during playback; outbound peers, trackers, and DHT are sufficient.
        .setBoolean(settings_pack.bool_types.enable_lsd.swigValue(), false)
        .setBoolean(settings_pack.bool_types.enable_upnp.swigValue(), false)
        .setBoolean(settings_pack.bool_types.enable_natpmp.swigValue(), false)

    private const val ENGINE_RELEASE_WAIT_SECONDS = 10L
}

/**
 * Owns exactly one libtorrent session and an authenticated loopback HTTP
 * server. The magnet enters through the platform channel but is never returned,
 * logged, or persisted. Only the bounded selected basename crosses back in
 * memory so Dart can verify episode identity; no directory path, tracker, or
 * peer address crosses the channel or appears in logs.
 */
internal class DirectTorrentManager(
    context: Context,
    private val sessionId: String = UUID.randomUUID().toString(),
) : AutoCloseable {
    private val appContext = context.applicationContext
    private val stopped = AtomicBoolean(false)
    private val metadataReady = CountDownLatch(1)
    private val torrentAdded = CountDownLatch(1)
    private val torrentRemoved = CountDownLatch(1)
    private val metadataFailure = AtomicReference<String?>(null)
    private val addFailed = AtomicBoolean(false)
    private val torrentHandle = AtomicReference<TorrentHandle?>(null)
    private val removingHandle = AtomicReference<TorrentHandle?>(null)
    private val pieceSignal = Object()
    private val priorityLock = Any()
    private val engineAcquired = AtomicBoolean(false)
    private val downloadSubmitted = AtomicBoolean(false)
    private val cacheRoot = File(appContext.cacheDir, CACHE_ROOT_NAME)
    private val sessionRoot = File(cacheRoot, sessionId)
    private val clientExecutor = Executors.newFixedThreadPool(3) { task ->
        Thread(task, "TetoTV-direct-torrent-http").apply { isDaemon = true }
    }
    private var serverSocket: ServerSocket? = null
    private var acceptThread: Thread? = null
    private var selectedFile: File? = null
    private var selectedFileSize = 0L
    private var selectedFileOffset = 0L
    private var selectedBasename = ""
    private var firstFilePiece = 0
    private var lastFilePiece = 0
    private var pieceLength = 0
    private var contentType = "application/octet-stream"
    private val capabilityToken = ByteArray(32).also(SecureRandom()::nextBytes)
        .joinToString(separator = "") { byte -> "%02x".format(byte) }

    private val alertListener = object : AlertListener {
        override fun types(): IntArray = intArrayOf(
            AlertType.ADD_TORRENT.swig(),
            AlertType.METADATA_RECEIVED.swig(),
            AlertType.METADATA_FAILED.swig(),
            AlertType.TORRENT_REMOVED.swig(),
            AlertType.PIECE_FINISHED.swig(),
            AlertType.TORRENT_ERROR.swig(),
            AlertType.FILE_ERROR.swig(),
        )

        override fun alert(alert: Alert<*>) {
            when (alert.type()) {
                AlertType.ADD_TORRENT -> {
                    val added = alert as AddTorrentAlert
                    if (added.error().isError) {
                        addFailed.set(true)
                        metadataFailure.compareAndSet(null, "DIRECT_TORRENT_ADD_FAILED")
                        metadataReady.countDown()
                    } else {
                        torrentHandle.set(added.handle())
                        if (added.handle().torrentFile() != null) metadataReady.countDown()
                    }
                    torrentAdded.countDown()
                }
                AlertType.METADATA_RECEIVED -> {
                    torrentHandle.compareAndSet(null, alert.handleOrNull())
                    metadataReady.countDown()
                }
                AlertType.METADATA_FAILED -> {
                    metadataFailure.compareAndSet(null, "DIRECT_TORRENT_METADATA_FAILED")
                    metadataReady.countDown()
                }
                AlertType.TORRENT_ERROR,
                AlertType.FILE_ERROR,
                -> {
                    metadataFailure.compareAndSet(null, "DIRECT_TORRENT_IO_FAILED")
                    metadataReady.countDown()
                    synchronized(pieceSignal) { pieceSignal.notifyAll() }
                }
                AlertType.PIECE_FINISHED ->
                    synchronized(pieceSignal) { pieceSignal.notifyAll() }
                AlertType.TORRENT_REMOVED -> {
                    if (removingHandle.get() != null) torrentRemoved.countDown()
                }
                else -> Unit
            }
        }
    }

    fun start(
        magnetUri: String,
        episode: Int?,
        preferredFileIndex: Int?,
        requestedSeason: Int? = null,
    ): DirectTorrentStartResult {
        validateMagnet(magnetUri)
        prepareCacheRoot()
        ensureRunning()
        try {
            DirectTorrentEngine.acquire(alertListener)
            engineAcquired.set(true)
            val flags = TorrentFlags.DEFAULT_DONT_DOWNLOAD.or_(
                TorrentFlags.SEQUENTIAL_DOWNLOAD,
            )
            DirectTorrentEngine.download(magnetUri, sessionRoot, flags)
            downloadSubmitted.set(true)
            if (!metadataReady.await(METADATA_TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
                throw DirectTorrentException(
                    "DIRECT_TORRENT_METADATA_TIMEOUT",
                    "Torrent metadata did not arrive in time.",
                )
            }
            ensureRunning()
            metadataFailure.get()?.let { code ->
                throw DirectTorrentException(code, "The torrent could not be prepared.")
            }
            val handle = torrentHandle.get()
                ?: throw DirectTorrentException(
                    "DIRECT_TORRENT_ADD_FAILED",
                    "The torrent could not be prepared.",
                )
            val info = handle.torrentFile()
                ?: throw DirectTorrentException(
                    "DIRECT_TORRENT_METADATA_FAILED",
                    "The torrent metadata is unavailable.",
                )
            configureSelectedFile(
                handle,
                info,
                episode,
                preferredFileIndex,
                requestedSeason,
            )
            val port = startLoopbackServer(handle)
            return DirectTorrentStartResult(
                sessionId = sessionId,
                playbackUrl = "http://127.0.0.1:$port/$capabilityToken",
                size = selectedFileSize,
                mimeType = contentType,
                selectedBasename = selectedBasename,
            )
        } catch (error: DirectTorrentException) {
            close()
            throw error
        } catch (_: Throwable) {
            close()
            throw DirectTorrentException(
                "DIRECT_TORRENT_START_FAILED",
                "Direct torrent playback could not start.",
            )
        }
    }

    private fun configureSelectedFile(
        handle: TorrentHandle,
        info: TorrentInfo,
        episode: Int?,
        preferredFileIndex: Int?,
        requestedSeason: Int?,
    ) {
        if (info.numFiles() <= 0 || info.numFiles() > DIRECT_TORRENT_MAX_FILE_COUNT) {
            throw DirectTorrentException(
                "DIRECT_TORRENT_METADATA_LIMIT",
                "This torrent contains too many files.",
            )
        }
        val storage = info.files()
        val candidates = (0 until info.numFiles()).map { index ->
            DirectTorrentFileCandidate(
                index = index,
                relativePath = storage.filePath(index),
                size = storage.fileSize(index),
                isPadFile = storage.padFileAt(index),
            )
        }
        val selected = DirectTorrentPolicy.chooseVideoFile(
            candidates,
            episode,
            preferredFileIndex,
            requestedSeason,
        ) ?: throw DirectTorrentException(
            "DIRECT_TORRENT_NO_VIDEO",
            "No supported episode video was found in this torrent.",
        )
        if (selected.size > DIRECT_TORRENT_MAX_FILE_BYTES) {
            throw DirectTorrentException(
                "DIRECT_TORRENT_FILE_LIMIT",
                "The selected video is larger than the 6 GB temporary-storage limit.",
            )
        }
        val availableBytes = StatFs(sessionRoot.absolutePath).availableBytes
        if (
            availableBytes > 0L &&
            availableBytes < selected.size + DIRECT_TORRENT_MIN_FREE_RESERVE_BYTES
        ) {
            throw DirectTorrentException(
                "DIRECT_TORRENT_STORAGE_LOW",
                "There is not enough free temporary storage for this video.",
            )
        }

        val canonicalRoot = sessionRoot.canonicalFile
        val resolvedFile = File(storage.filePath(selected.index, canonicalRoot.path)).canonicalFile
        val rootPrefix = canonicalRoot.path + File.separator
        if (!resolvedFile.path.startsWith(rootPrefix)) {
            throw DirectTorrentException(
                "DIRECT_TORRENT_UNSAFE_PATH",
                "The torrent contains an unsafe file path.",
            )
        }

        val priorities = Priority.array(Priority.IGNORE, info.numFiles())
        priorities[selected.index] = Priority.TOP_PRIORITY
        handle.prioritizeFiles(priorities)
        selectedFile = resolvedFile
        selectedFileSize = selected.size
        selectedFileOffset = storage.fileOffset(selected.index)
        selectedBasename = DirectTorrentPolicy.selectedBasename(selected.relativePath)
        if (selectedBasename.isEmpty()) {
            throw DirectTorrentException(
                "DIRECT_TORRENT_METADATA_FAILED",
                "The selected video metadata is invalid.",
            )
        }
        pieceLength = info.pieceLength()
        if (pieceLength <= 0) {
            throw DirectTorrentException(
                "DIRECT_TORRENT_METADATA_FAILED",
                "The torrent metadata is invalid.",
            )
        }
        firstFilePiece = (selectedFileOffset / pieceLength).toInt()
        lastFilePiece = ((selectedFileOffset + selectedFileSize - 1L) / pieceLength).toInt()
        contentType = mimeTypeFor(selected.relativePath)
        handle.setSequentialRange(firstFilePiece, lastFilePiece)
        handle.resume()
        prioritizeForOffset(handle, 0L)
    }

    private fun startLoopbackServer(handle: TorrentHandle): Int {
        val server = ServerSocket().apply {
            reuseAddress = false
            bind(
                InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0),
                LOOPBACK_BACKLOG,
            )
        }
        serverSocket = server
        acceptThread = Thread(
            {
                while (!stopped.get()) {
                    val socket = runCatching { server.accept() }.getOrNull() ?: break
                    clientExecutor.execute { serveClient(socket, handle) }
                }
            },
            "TetoTV-direct-torrent-accept",
        ).apply {
            isDaemon = true
            start()
        }
        return server.localPort
    }

    private fun serveClient(socket: Socket, handle: TorrentHandle) {
        socket.use { client ->
            try {
                client.soTimeout = REQUEST_HEADER_TIMEOUT_MS
                client.tcpNoDelay = true
                val input = BufferedInputStream(client.getInputStream())
                val output = BufferedOutputStream(client.getOutputStream())
                val request = readRequest(input)
                if (request == null || request.path != "/$capabilityToken") {
                    writeSimpleResponse(output, 404, "Not Found")
                    return
                }
                if (request.method != "GET" && request.method != "HEAD") {
                    writeSimpleResponse(output, 405, "Method Not Allowed", "Allow: GET, HEAD\r\n")
                    return
                }
                val range = try {
                    DirectTorrentPolicy.parseRange(request.range, selectedFileSize)
                } catch (_: DirectTorrentRangeException) {
                    writeSimpleResponse(
                        output,
                        416,
                        "Range Not Satisfiable",
                        "Content-Range: bytes */$selectedFileSize\r\n",
                    )
                    return
                }
                val selectedRange = range ?: DirectTorrentByteRange(
                    start = 0L,
                    endInclusive = selectedFileSize - 1L,
                )
                val status = if (range == null) "200 OK" else "206 Partial Content"
                output.write("HTTP/1.1 $status\r\n".toByteArray(StandardCharsets.US_ASCII))
                output.write("Accept-Ranges: bytes\r\n".toByteArray(StandardCharsets.US_ASCII))
                output.write("Content-Type: $contentType\r\n".toByteArray(StandardCharsets.US_ASCII))
                output.write(
                    "Content-Length: ${selectedRange.length}\r\n".toByteArray(
                        StandardCharsets.US_ASCII,
                    ),
                )
                if (range != null) {
                    output.write(
                        "Content-Range: bytes ${range.start}-${range.endInclusive}/$selectedFileSize\r\n"
                            .toByteArray(StandardCharsets.US_ASCII),
                    )
                }
                output.write("Cache-Control: no-store\r\n".toByteArray(StandardCharsets.US_ASCII))
                output.write("Connection: close\r\n\r\n".toByteArray(StandardCharsets.US_ASCII))
                output.flush()
                if (request.method == "HEAD") return

                prioritizeForOffset(handle, selectedRange.start)
                streamRange(output, handle, selectedRange)
            } catch (_: Throwable) {
                // Deliberately do not log the exception. Native and filesystem
                // errors can contain peer endpoints, magnet data, or paths.
            }
        }
    }

    private fun streamRange(
        output: BufferedOutputStream,
        handle: TorrentHandle,
        range: DirectTorrentByteRange,
    ) {
        val file = selectedFile ?: return
        var position = range.start
        var remaining = range.length
        var randomAccess: RandomAccessFile? = null
        try {
            while (remaining > 0L && !stopped.get()) {
                val chunkSize = minOf(HTTP_CHUNK_BYTES.toLong(), remaining).toInt()
                waitForPieces(handle, position, chunkSize)
                ensureRunning()
                if (randomAccess == null) randomAccess = RandomAccessFile(file, "r")
                randomAccess.seek(position)
                val buffer = ByteArray(chunkSize)
                var filled = 0
                while (filled < buffer.size) {
                    val read = randomAccess.read(buffer, filled, buffer.size - filled)
                    if (read < 0) {
                        throw DirectTorrentException(
                            "DIRECT_TORRENT_READ_FAILED",
                            "The temporary stream ended unexpectedly.",
                        )
                    }
                    filled += read
                }
                output.write(buffer)
                output.flush()
                position += chunkSize
                remaining -= chunkSize
            }
        } finally {
            runCatching { randomAccess?.close() }
        }
    }

    private fun waitForPieces(handle: TorrentHandle, fileOffset: Long, length: Int) {
        val globalStart = selectedFileOffset + fileOffset
        val globalEnd = globalStart + length - 1L
        val firstPiece = (globalStart / pieceLength).toInt()
        val lastPiece = (globalEnd / pieceLength).toInt()
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(PIECE_WAIT_TIMEOUT_SECONDS)
        while (!stopped.get()) {
            val ready = (firstPiece..lastPiece).all(handle::havePiece)
            if (ready) return
            metadataFailure.get()?.let {
                throw DirectTorrentException(
                    "DIRECT_TORRENT_IO_FAILED",
                    "The torrent stream encountered a storage or network error.",
                )
            }
            val remainingNanos = deadline - System.nanoTime()
            if (remainingNanos <= 0L) {
                throw DirectTorrentException(
                    "DIRECT_TORRENT_PIECE_TIMEOUT",
                    "Torrent peers did not provide the requested video data in time.",
                )
            }
            synchronized(pieceSignal) {
                pieceSignal.wait(
                    minOf(TimeUnit.NANOSECONDS.toMillis(remainingNanos), PIECE_POLL_MS)
                        .coerceAtLeast(1L),
                )
            }
        }
        ensureRunning()
    }

    private fun prioritizeForOffset(handle: TorrentHandle, fileOffset: Long) {
        val piece = ((selectedFileOffset + fileOffset) / pieceLength).toInt()
            .coerceIn(firstFilePiece, lastFilePiece)
        synchronized(priorityLock) {
            if (stopped.get()) return
            handle.clearPieceDeadlines()
            handle.setSequentialRange(piece, lastFilePiece)
            val deadlineEnd = minOf(lastFilePiece, piece + PIECE_DEADLINE_WINDOW - 1)
            for (index in piece..deadlineEnd) {
                handle.setPieceDeadline(index, (index - piece) * PIECE_DEADLINE_STEP_MS)
            }
        }
    }

    override fun close() {
        if (!stopped.compareAndSet(false, true)) return
        metadataReady.countDown()
        synchronized(pieceSignal) { pieceSignal.notifyAll() }
        runCatching { serverSocket?.close() }
        runCatching { acceptThread?.interrupt() }
        clientExecutor.shutdownNow()
        var removalConfirmed = true
        if (engineAcquired.get() && downloadSubmitted.get()) {
            var handle = torrentHandle.get()
            if (handle == null) {
                runCatching {
                    torrentAdded.await(ADD_TORRENT_CLOSE_WAIT_SECONDS, TimeUnit.SECONDS)
                }
                handle = torrentHandle.get()
            }
            if (handle == null) {
                // Without either an add error or a handle, an asynchronous add
                // may still arrive after the listener is removed. Never resume
                // this process-lifetime engine in that uncertain state.
                removalConfirmed = addFailed.get()
            } else {
                removingHandle.set(handle)
                val removalRequested = DirectTorrentEngine.remove(handle)
                val removedAlert = removalRequested && runCatching {
                    torrentRemoved.await(TORRENT_REMOVE_WAIT_SECONDS, TimeUnit.SECONDS)
                }.getOrDefault(false)
                val noLongerInSession = removalRequested && runCatching {
                    !handle.inSession()
                }.getOrDefault(false)
                removalConfirmed = removedAlert || noLongerInSession
                torrentHandle.compareAndSet(handle, null)
            }
        }
        if (!removalConfirmed) DirectTorrentEngine.poison()
        if (engineAcquired.compareAndSet(true, false)) {
            DirectTorrentEngine.release(alertListener)
        }
        deleteSessionCache()
    }

    private fun prepareCacheRoot() {
        val canonicalAppCache = appContext.cacheDir.canonicalFile
        val canonicalRoot = cacheRoot.canonicalFile
        if (!canonicalRoot.path.startsWith(canonicalAppCache.path + File.separator)) {
            throw DirectTorrentException(
                "DIRECT_TORRENT_CACHE_FAILED",
                "The temporary torrent cache is unavailable.",
            )
        }
        if (!canonicalRoot.exists() && !canonicalRoot.mkdirs()) {
            throw DirectTorrentException(
                "DIRECT_TORRENT_CACHE_FAILED",
                "The temporary torrent cache could not be created.",
            )
        }
        canonicalRoot.listFiles()?.forEach { stale -> safeDelete(stale, canonicalRoot) }
        if (!sessionRoot.mkdirs() && !sessionRoot.isDirectory) {
            throw DirectTorrentException(
                "DIRECT_TORRENT_CACHE_FAILED",
                "The temporary torrent cache could not be created.",
            )
        }
    }

    private fun deleteSessionCache() {
        val canonicalRoot = runCatching { cacheRoot.canonicalFile }.getOrNull() ?: return
        safeDelete(sessionRoot, canonicalRoot)
    }

    private fun safeDelete(target: File, root: File) {
        val canonicalTarget = runCatching { target.canonicalFile }.getOrNull() ?: return
        if (!canonicalTarget.path.startsWith(root.path + File.separator)) return
        canonicalTarget.listFiles()?.forEach { child -> safeDelete(child, canonicalTarget) }
        runCatching { canonicalTarget.delete() }
    }

    private fun validateMagnet(value: String) {
        val normalized = value.lowercase(Locale.ROOT)
        if (
            value.length !in 20..MAX_MAGNET_CHARACTERS ||
            !normalized.startsWith("magnet:?") ||
            !("xt=urn:btih:" in normalized || "xt=urn:btmh:" in normalized)
        ) {
            throw DirectTorrentException(
                "DIRECT_TORRENT_INVALID_MAGNET",
                "The selected release does not contain a valid magnet link.",
            )
        }
    }

    private fun ensureRunning() {
        if (stopped.get()) {
            throw DirectTorrentException(
                "DIRECT_TORRENT_STOPPED",
                "Direct torrent playback was stopped.",
            )
        }
    }

    private fun Alert<*>.handleOrNull(): TorrentHandle? =
        (this as? org.libtorrent4j.alerts.TorrentAlert<*>)?.handle()

    private data class HttpRequest(
        val method: String,
        val path: String,
        val range: String?,
    )

    private fun readRequest(input: BufferedInputStream): HttpRequest? {
        val bytes = ArrayList<Byte>(1_024)
        var matched = 0
        val terminator = byteArrayOf(13, 10, 13, 10)
        while (bytes.size < MAX_REQUEST_HEADER_BYTES) {
            val value = input.read()
            if (value < 0) return null
            val byte = value.toByte()
            bytes.add(byte)
            matched = if (byte == terminator[matched]) matched + 1 else if (byte == 13.toByte()) 1 else 0
            if (matched == terminator.size) break
        }
        if (matched != terminator.size) return null
        val raw = ByteArray(bytes.size) { index -> bytes[index] }
            .toString(StandardCharsets.US_ASCII)
        val lines = raw.split("\r\n")
        val first = lines.firstOrNull()?.split(' ') ?: return null
        if (first.size != 3 || !first[2].startsWith("HTTP/1.")) return null
        val range = lines.drop(1).firstOrNull { line ->
            line.startsWith("Range:", ignoreCase = true)
        }?.substringAfter(':')?.trim()
        return HttpRequest(first[0].uppercase(Locale.ROOT), first[1], range)
    }

    private fun writeSimpleResponse(
        output: BufferedOutputStream,
        status: Int,
        reason: String,
        extraHeaders: String = "",
    ) {
        output.write(
            "HTTP/1.1 $status $reason\r\n${extraHeaders}Content-Length: 0\r\nConnection: close\r\n\r\n"
                .toByteArray(StandardCharsets.US_ASCII),
        )
        output.flush()
    }

    private fun mimeTypeFor(path: String): String = when (
        path.substringAfterLast('.', missingDelimiterValue = "").lowercase(Locale.ROOT)
    ) {
        "mkv" -> "video/x-matroska"
        "mp4", "m4v" -> "video/mp4"
        "webm" -> "video/webm"
        "ts", "m2ts" -> "video/mp2t"
        "avi" -> "video/x-msvideo"
        "mov" -> "video/quicktime"
        else -> "application/octet-stream"
    }

    companion object {
        private const val CACHE_ROOT_NAME = "direct-torrent"
        private const val MAX_MAGNET_CHARACTERS = 8_192
        private const val METADATA_TIMEOUT_SECONDS = 45L
        private const val ADD_TORRENT_CLOSE_WAIT_SECONDS = 5L
        private const val TORRENT_REMOVE_WAIT_SECONDS = 5L
        private const val PIECE_WAIT_TIMEOUT_SECONDS = 120L
        private const val PIECE_POLL_MS = 500L
        private const val PIECE_DEADLINE_WINDOW = 24
        private const val PIECE_DEADLINE_STEP_MS = 125
        private const val LOOPBACK_BACKLOG = 8
        private const val REQUEST_HEADER_TIMEOUT_MS = 10_000
        private const val MAX_REQUEST_HEADER_BYTES = 16 * 1_024
        private const val HTTP_CHUNK_BYTES = 128 * 1_024
    }
}
