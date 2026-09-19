package io.flutter.plugin.platform;

/** Package-private Flutter accessor used only by the separate instrumentation APK. */
public final class Media3FixtureViewAccess {
    public static PlatformViewFactory factory(PlatformViewRegistry registry) {
        return ((PlatformViewRegistryImpl) registry).getFactory("dev.tetotv/media3/video");
    }
}
