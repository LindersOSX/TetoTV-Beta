# Premiumize integration

TetoTV supports a user's personal Premiumize API key. The key is validated
with `/api/account/info`, sent only as a Bearer authorization header, and saved
with Android Keystore-backed secure storage after an active plan is confirmed.
It is never placed in a URL, project configuration, release asset, or source
repository.

Premiumize OAuth device authorization requires a registered OAuth client, so
the public APK uses the official personal API-key path without embedding an
application secret.

## Episode flow

TetoTV first calls `/api/cache/check`. It calls `/api/transfer/directdl` only
for an item Premiumize reports as cached, chooses the matching episode file,
and passes that HTTPS link to the debrid-only player gate. A cache miss never
creates or polls a Premiumize cloud transfer.

Official API documentation: <https://www.premiumize.me/api>.
