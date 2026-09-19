package dev.animetv.anime_tv.player

import android.app.Instrumentation
import android.content.Intent
import android.os.StrictMode
import android.widget.FrameLayout
import io.flutter.embedding.android.FlutterSurfaceView
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.Media3FixtureViewAccess
import io.flutter.plugin.platform.PlatformView
import java.net.InetAddress
import java.net.ServerSocket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** First-party synthetic media only. Exercises the production bridge, not a mock player. */
object Media3PlaybackInstrumentation {
    fun run(test: Instrumentation, publicHttps: Boolean = false): String {
        val activity = test.startActivitySync(Intent(test.targetContext, Media3FixtureActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as Media3FixtureActivity
        val files = test.context.assets.list("media3-fixture").orEmpty().associateWith {
            test.context.assets.open("media3-fixture/$it").use { input -> input.readBytes() }
        }
        check(files.isNotEmpty()) { "Synthetic playback fixture missing" }
        val server = ServerSocket(0, 4, InetAddress.getByName("127.0.0.1"))
        val http = Executors.newCachedThreadPool()
        http.submit {
            while (!server.isClosed) {
                val socket = runCatching { server.accept() }.getOrNull() ?: break
                http.submit {
                    socket.use {
                        runCatching {
                            it.soTimeout = 5000
                            val input = it.getInputStream().bufferedReader()
                            val name = input.readLine()?.split(' ')?.getOrNull(1)?.substringAfterLast('/')
                            while (!input.readLine().isNullOrEmpty()) { /* bounded test-only requests */ }
                            val bytes = files[name] ?: error("Unknown synthetic fixture")
                            val type = if (name!!.endsWith(".m3u8")) "application/vnd.apple.mpegurl" else "video/mp2t"
                            it.getOutputStream().apply {
                                write("HTTP/1.1 200 OK\r\nContent-Type: $type\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n\r\n".toByteArray())
                                write(bytes)
                                flush()
                            }
                        }
                    }
                }
            }
        }
        lateinit var engine: FlutterEngine
        lateinit var bridge: Media3FlutterBridge
        lateinit var flutterSurface: FlutterSurfaceView
        lateinit var flutterView: FlutterView
        lateinit var videoContainer: FrameLayout
        var oldPolicy: StrictMode.ThreadPolicy? = null
        val state = AtomicReference<Map<*, *>>(emptyMap<Any, Any>())
        test.runOnMainSync {
            oldPolicy = StrictMode.getThreadPolicy()
            StrictMode.setThreadPolicy(StrictMode.ThreadPolicy.Builder().detectNetwork().penaltyDeathOnNetwork().build())
            engine = FlutterEngine(activity, null, false)
            // Mirror the real activity: attach a rendering surface before
            // registering external textures. A headless engine has not yet
            // selected its graphics backend and cannot accept a texture.
            flutterSurface = FlutterSurfaceView(activity)
            flutterView = FlutterView(activity, flutterSurface)
            activity.content.addView(flutterView, FrameLayout.LayoutParams(640, 360))
            flutterView.attachToFlutterEngine(engine)
            videoContainer = FrameLayout(activity)
            activity.content.addView(videoContainer, FrameLayout.LayoutParams(640, 360))
        }
        val surfaceDeadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
        while (!flutterSurface.holder.surface.isValid && System.nanoTime() < surfaceDeadline) Thread.sleep(50)
        check(flutterSurface.holder.surface.isValid) { "Flutter rendering surface did not attach" }
        test.runOnMainSync {
            // Public texture fallback used only on the affected Fire TV model.
            repeat(3) {
                val texture = com.alexmercerind.media_kit_video.FireTvSurfaceProducer(engine.renderer)
                texture.setSize(320, 180)
                check(texture.width == 320 && texture.height == 180)
                val surface = texture.surface
                check(surface.isValid)
                val canvas = surface.lockCanvas(null)
                canvas.drawColor(android.graphics.Color.BLUE)
                surface.unlockCanvasAndPost(canvas)
                texture.setSize(640, 360)
                check(texture.surface === surface)
                texture.release()
                texture.release()
                check(!surface.isValid)
            }
            bridge = Media3FlutterBridge(activity, engine)
            bridge.onListen(null, object : EventChannel.EventSink {
                override fun success(event: Any?) { if (event is Map<*, *>) state.set(event) }
                override fun error(code: String, message: String?, details: Any?) = Unit
                override fun endOfStream() = Unit
            })
        }
        val failures = mutableListOf<String>()
        fun invoke(name: String, args: Map<String, Any?> = emptyMap()): Any? {
            val latch = CountDownLatch(1)
            val result = AtomicReference<Any?>()
            val failure = AtomicReference<String?>()
            test.runOnMainSync {
                bridge.onMethodCall(MethodCall(name, args), object : MethodChannel.Result {
                    override fun success(value: Any?) { result.set(value); latch.countDown() }
                    override fun error(code: String, message: String?, details: Any?) {
                        failure.set("$name:$code:$details"); latch.countDown()
                    }
                    override fun notImplemented() { failure.set("$name:not_implemented"); latch.countDown() }
                })
            }
            check(latch.await(10, TimeUnit.SECONDS)) { "$name did not reply" }
            check(failure.get() == null) { failure.get().orEmpty() }
            return result.get()
        }
        var played = 0
        try {
            val mimeTypes = mutableListOf("application/x-mpegURL", "application/vnd.apple.mpegurl",
                "APPLICATION/VND.APPLE.MPEGURL; charset=UTF-8", "application/x-mpegurl")
            if (publicHttps) mimeTypes += "video/mp4"
            for ((index, mime) in mimeTypes.withIndex()) {
                val id = (invoke("create") as Map<*, *>)["id"] as Number
                var view: PlatformView? = null
                state.set(emptyMap<Any, Any>())
                try {
                    test.runOnMainSync {
                        view = Media3FixtureViewAccess.factory(engine.platformViewsController.registry)
                            .create(activity, index, mapOf("id" to id, "surfaceType" to if (index % 2 == 0) "surface" else "texture"))
                        videoContainer.addView(view.view, FrameLayout.LayoutParams(640, 360))
                    }
                    val root = "http://127.0.0.1:${server.localPort}"
                    val uri = if (index == 4) "https://storage.googleapis.com/exoplayer-test-media-0/BigBuckBunny_320x180.mp4" else "$root/index.m3u8"
                    invoke("open", mapOf("id" to id, "openId" to 1, "uri" to uri,
                        "mimeType" to mime, "play" to true,
                        "audioTracks" to if (index == 2) listOf(mapOf("uri" to "$root/audio.m3u8",
                            "mimeType" to "application/vnd.apple.mpegurl", "language" to "en")) else emptyList<Any>()))
                    val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(15)
                    while (System.nanoTime() < deadline) {
                        val current = state.get()
                        check(current["error"] == null) { "playback:${current["error"]}" }
                        if (current["renderedFirstFrame"] == true && (current["positionMs"] as? Number)?.toLong()?.let { it >= 800 } == true) break
                        Thread.sleep(50)
                    }
                    check(state.get()["renderedFirstFrame"] == true) { "No rendered frame" }
                    check((state.get()["positionMs"] as Number).toLong() >= 800) { "Playback did not advance" }
                    invoke("pause", mapOf("id" to id))
                    invoke("seek", mapOf("id" to id, "positionMs" to 1000))
                    invoke("play", mapOf("id" to id))
                    invoke("stop", mapOf("id" to id))
                    played++
                } catch (error: Exception) {
                    failures += "case$index:${error.message}"
                } finally {
                    test.runOnMainSync { videoContainer.removeAllViews(); view?.dispose() }
                    try { invoke("dispose", mapOf("id" to id)) } catch (error: Exception) { failures += "dispose$index:${error.message}" }
                    // Repeated cleanup must be harmless, including the next-episode path.
                    invoke("dispose", mapOf("id" to id))
                }
            }
            check(failures.isEmpty()) { failures.joinToString("; ") }
            return "PASS: $played opens rendered frames and advanced; HLS aliases; SurfaceView + TextureView; external HLS audio; HTTPS=$publicHttps; pause/seek/stop; repeated dispose and fresh sessions; main-thread network forbidden; Fire TV fallback allocation/drawing/resize/release"
        } finally {
            test.runOnMainSync {
                bridge.close(); flutterView.detachFromFlutterEngine(); engine.destroy(); activity.finish()
                oldPolicy?.let(StrictMode::setThreadPolicy)
            }
            server.close()
            http.shutdownNow()
        }
    }
}
