# AllDebrid integration

TetoTV supports AllDebrid through its official API and never embeds a shared
account credential.

## Account setup

1. Choose **AllDebrid** under **Settings > Streaming**.
2. Use **Connect by phone** to start AllDebrid's PIN flow, or enter a personal
   API key manually.
3. TetoTV validates the key with the authenticated user endpoint and requires
   an active premium account before saving it with Android Keystore-backed
   secure storage.

The PIN flow uses `/v4.1/pin/get` and `/v4/pin/check`. Disconnecting removes
the saved key from the device.

## Episode flow

For a release explicitly selected by the user, TetoTV uploads its magnet and
uses the documented `ready` response as the earliest cache signal. If it is
not immediately ready, TetoTV deletes it and never polls for a cloud download.
For a ready result it obtains `/v4/magnet/files`, chooses the matching episode,
and unlocks only that file's link. Only the resulting HTTPS link reaches the
player. Because upload is the provider's first supported cache signal, a miss
may exist briefly before that immediate deletion.

Official API documentation: <https://docs.alldebrid.com/>.
