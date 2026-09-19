package com.alexmercerind.media_kit_video;

import android.view.Surface;
import io.flutter.view.TextureRegistry;

/**
 * App-owned compatibility adapter using Flutter's public texture API.
 * AFTKRT / Fire OS API 30 can hang its main thread in ImageReader's native
 * acquireLatestImage path. Use the supported pre-ImageReader texture path
 * only on that observed device family. No global/debug renderer flags.
 */
public final class FireTvSurfaceProducer implements TextureRegistry.SurfaceProducer {
    private final TextureRegistry.SurfaceTextureEntry entry;
    private final Surface surface;
    private int width = 1;
    private int height = 1;
    private boolean released;

    public static boolean needsCompatibility(String manufacturer, String model, int sdk) {
        return sdk == 30 && "Amazon".equalsIgnoreCase(manufacturer)
                && "AFTKRT".equalsIgnoreCase(model);
    }

    public FireTvSurfaceProducer(TextureRegistry registry) {
        entry = registry.createSurfaceTexture();
        entry.surfaceTexture().setDefaultBufferSize(width, height);
        surface = new Surface(entry.surfaceTexture());
    }

    @Override public long id() { return entry.id(); }
    @Override public int getWidth() { return width; }
    @Override public int getHeight() { return height; }
    @Override public Surface getSurface() {
        if (released) throw new IllegalStateException("Video surface released");
        return surface;
    }
    @Override public Surface getForcedNewSurface() {
        // This stable SurfaceTexture has no ImageReader image cache to reset.
        return getSurface();
    }
    @Override public void setSize(int width, int height) {
        if (released) return;
        if (width <= 0 || height <= 0) throw new IllegalArgumentException("Invalid video dimensions");
        entry.surfaceTexture().setDefaultBufferSize(width, height);
        this.width = width;
        this.height = height;
    }
    @Override public void setCallback(TextureRegistry.SurfaceProducer.Callback callback) {
        // Unlike ImageReader, this texture remains valid through background /
        // resume. VideoOutput supplies the existing explicit cleanup callback.
    }
    @Override public void scheduleFrame() {
        // The registry's SurfaceTexture listener schedules new frames itself.
    }
    @Override public boolean handlesCropAndRotation() { return false; }
    @Override public void release() {
        if (released) return;
        released = true;
        surface.release();
        entry.release();
    }
}
