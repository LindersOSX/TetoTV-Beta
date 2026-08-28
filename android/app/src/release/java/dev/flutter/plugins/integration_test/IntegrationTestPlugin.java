package dev.flutter.plugins.integration_test;

import androidx.annotation.NonNull;

import io.flutter.embedding.engine.plugins.FlutterPlugin;

/**
 * Release-only compatibility shim for Flutter 3.44.
 *
 * <p>Flutter 3.44 generates a main-source registrant entry for dev-only native
 * plugins while correctly excluding those plugins from the release classpath.
 * That makes release compilation fail when integration_test remains in
 * dev_dependencies as required by Flutter's own documentation. Debug and test
 * builds still use the SDK's real IntegrationTestPlugin; production registers
 * this intentionally empty implementation until the toolchain regression is
 * fixed.</p>
 */
public final class IntegrationTestPlugin implements FlutterPlugin {
    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        // Integration-test channels must never be active in production.
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        // Nothing was registered.
    }
}
