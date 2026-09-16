// Adapted from Aniyomi extensions-lib 17-rc2; Apache-2.0.
package eu.kanade.tachiyomi.animesource.model

open class ThumbnailInfo(val tileInfo: List<TileInfo>, val imageTileUrls: List<String>)

data class TileInfo(
    val imageIndex: Int,
    val timeMs: Long,
    val x: Int,
    val y: Int,
    val width: Int,
    val height: Int,
)
