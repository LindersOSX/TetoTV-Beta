package dev.animetv.anime_tv.player

import android.app.Activity
import android.os.Bundle
import android.widget.FrameLayout

/** Debug/test variant only: no business logic, account data, or Dart entry point. */
class Media3FixtureActivity : Activity() {
    lateinit var content: FrameLayout
        private set
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        content = FrameLayout(this)
        setContentView(content)
    }
}
