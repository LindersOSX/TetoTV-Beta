package dev.animetv.anime_tv

/** Selects an authentication API supported by Discord's Android SDK build. */
internal object DiscordAuthFlowPolicy {
    /**
     * `GetTokenFromDevice` is a console capability. Discord's Android AAR
     * terminates the process with `Check failed: CanAuthorizeDevice` when it
     * is called, including on Android/Google/Fire TV. Android TVs must use the
     * supported mobile PKCE `Authorize` flow just like Android phones.
     */
    fun shouldUseDeviceFlow(uiMode: Int, hasLeanback: Boolean): Boolean = false

    /**
     * The Android Social SDK opens a browser/custom tab. TV linking is owned
     * by Flutter's in-app QR device flow and must never enter that SDK path.
     */
    fun allowsMobileOAuth(isTelevision: Boolean): Boolean = !isTelevision
}
