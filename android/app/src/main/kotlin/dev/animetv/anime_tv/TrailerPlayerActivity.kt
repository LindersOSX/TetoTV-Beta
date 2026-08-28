package dev.animetv.anime_tv

import android.annotation.SuppressLint
import android.app.Activity
import android.graphics.Color
import android.os.Bundle
import android.view.Gravity
import android.view.ViewGroup
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.FrameLayout

/** Provider-hosted trailer playback which never leaves the TetoTV package. */
class TrailerPlayerActivity : Activity() {
    private var webView: WebView? = null

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setResult(RESULT_CANCELED)
        val request = TrailerPlaybackPolicy.request(
            intent.getStringExtra(EXTRA_PROVIDER),
            intent.getStringExtra(EXTRA_VIDEO_ID),
            intent.getStringExtra(EXTRA_TITLE),
        )
        if (request == null) {
            setResult(RESULT_CANCELED)
            finish()
            return
        }

        window.statusBarColor = Color.BLACK
        window.navigationBarColor = Color.BLACK
        val root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        val player = WebView(this).apply {
            id = android.view.View.generateViewId()
            setBackgroundColor(Color.BLACK)
            isFocusable = true
            isFocusableInTouchMode = true
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.mediaPlaybackRequiresUserGesture = false
            settings.allowFileAccess = false
            settings.allowContentAccess = false
            settings.javaScriptCanOpenWindowsAutomatically = false
            webChromeClient = WebChromeClient()
            webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(
                    view: WebView,
                    navigation: WebResourceRequest,
                ): Boolean = navigation.isForMainFrame
            }
        }
        webView = player
        root.addView(
            player,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )

        val density = resources.displayMetrics.density
        val back = Button(this).apply {
            id = android.view.View.generateViewId()
            text = "Back"
            contentDescription = "Back to anime details"
            setTextColor(Color.WHITE)
            setBackgroundColor(Color.argb(210, 20, 20, 24))
            isAllCaps = false
            isFocusable = true
            nextFocusDownId = player.id
            setOnClickListener { finishTrailer() }
        }
        player.nextFocusUpId = back.id
        root.addView(
            back,
            FrameLayout.LayoutParams(
                (132 * density).toInt(),
                (58 * density).toInt(),
                Gravity.TOP or Gravity.START,
            ).apply {
                leftMargin = (20 * density).toInt()
                topMargin = (18 * density).toInt()
            },
        )
        setContentView(root)

        val embed = TrailerPlaybackPolicy.embedUrl(request)
        val html = """
            <!doctype html><html><head>
            <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
            <style>html,body,iframe{margin:0;width:100%;height:100%;background:#000;border:0;overflow:hidden}</style>
            </head><body>
            <iframe src="$embed" title="Anime trailer" allow="autoplay; encrypted-media; fullscreen" allowfullscreen></iframe>
            </body></html>
        """.trimIndent()
        player.loadDataWithBaseURL(
            "https://github.com/LindersOSX/TetoTV-Beta/",
            html,
            "text/html",
            "UTF-8",
            null,
        )
        // Android's default physical-Back handling finishes the Activity
        // without calling [finishTrailer]. Mark the result successful only
        // after the validated trailer player has been created and loaded so
        // every normal exit returns to the details page without a false
        // playback error. Invalid requests still return RESULT_CANCELED.
        setResult(RESULT_OK)
        back.requestFocus()
    }

    override fun onDestroy() {
        webView?.apply {
            stopLoading()
            loadUrl("about:blank")
            clearHistory()
            removeAllViews()
            destroy()
        }
        webView = null
        super.onDestroy()
    }

    private fun finishTrailer() {
        setResult(RESULT_OK)
        finish()
    }

    companion object {
        const val EXTRA_PROVIDER = "provider"
        const val EXTRA_VIDEO_ID = "video_id"
        const val EXTRA_TITLE = "title"
    }
}
