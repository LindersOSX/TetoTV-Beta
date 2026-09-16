# Local unreleased diagnostic improvements

This change improves evidence quality; it cannot guarantee a diagnosis for
every crash, hardware/driver problem, process kill, or remote-service failure.
No report should require a customer to supply credentials or media URLs.

## What is added

- Explicit support exports include `uiRuntime`: current static screen/control
  categories, logical/physical viewport, UI language and text scale, configured
  player/rendering mode, focus rectangles and temporary ordinals, scroll metrics,
  lifecycle, and a newest-retained navigation trail. At most 64 coalesced events
  from five minutes are kept, with counts for omitted/coalesced events.
- At most 120 recent Flutter build/raster samples are summarized as averages,
  maxima and p95 timings. These measure UI work, not native video FPS.
- Opted-in Dart reports freeze a compact UI snapshot synchronously at capture,
  before a pending upload or platform query can change the apparent context.
  Original code-frame package paths and line/column numbers survive multiple
  privacy filters; arbitrary package URIs and filesystem paths do not.
- A queued crash keeps the version/build recorded at the crash, even if the
  app has been upgraded before it is delivered. Older records without build
  provenance use the protocol-compatible `0.0.0` / `1` unknown sentinel; those
  values are not a claim that the customer was using that version.
- Native summaries add safe thread state/flags, process uptime, coarse fault
  address categories, structured memory-error type, memory-pressure breadcrumbs
  when Android provides them, accurate raw trace byte counts, and explicit
  truncation markers. Raw tombstones are never sent.
- Manga image failures retain HTTP status, actual received-byte count,
  allowlisted magic-derived format, redirect count, and a changed-origin boolean.
  HTML/AVIF/HEIF classification is diagnostic only, not permission to decode
  unsafe or unsupported payloads. Requests that advertised unsupported AVIF/HEIF
  now prefer the existing supported image types.
- Experimental Aniyomi reports identify the validated public extension package,
  extension/API version, isolated-runtime revision and supported capability
  flags. Each provider attempt records a fixed operation stage and outcome,
  scheduler/queue timing, conservative title and episode-match counts, bounded
  original/returned/filtered/truncated result counts, playable/rejected video
  counts, and the HTTP broker's status class, redirect count, response-size
  bucket and fixed failure class. This distinguishes source-construction,
  matching, extraction, network-policy, timeout and unsupported-runtime failures
  without recording the requested show or chapter.

## Privacy and transport boundaries

The UI trail lives only in RAM. It has no network client, persistence, stable
device/user ID, or raw route/label/text fields. Native/custom text-entry controls
and keyboard subtrees suppress navigation events, focus geometry, and focus
ordinals entirely, including action keys. Only entering/leaving text-entry mode
is recorded. Typed characters and character counts are never collected.

Automatic delivery still requires the loaded anonymous-crash preference. That
preference starts enabled only on genuinely new installs, is disclosed with an
opt-out, and preserves upgraded installations and explicit opt-outs. Manual
export/copy/support actions include the local UI snapshot independently of that
setting. Error strings and stacks still pass the existing privacy redactor.

The automatic wire schema stays v1 with exactly the existing fields. Additional
context shares the bounded stack field: at most 4,000 characters, 8,000 UTF-8
bytes after JSON escaping and 50 lines, plus a 500-character error message.
Non-layout control characters are removed. Truncation is indicated.
The broker and native queue do not need deployment or relaxed validation.
Explicit reports retain the existing 480,000-character maximum and valid-JSON
size-reduction/completeness metadata.

## Reading the evidence

For a focus jump, compare consecutive navigation/focus events and rectangles.
Temporary ordinals identify a control only within this running process; they
are not media IDs and cannot identify the customer's selected title.

For manga load failures, inspect `reason_code`, `status`, and the fixed-format
diagnostic `message`. Do not infer a previous customer's file format from an
older report that omitted it. A format category does not prove that an image is
valid, and a 200 response can still be HTML or an unsupported image.

For Aniyomi failures, start with `extension_package`, `extension_version`,
`api_version`, `stage`, `reason_code` and `outcome`. A `source_construct`
failure happens before a provider can search. A successful search with zero
exact title or episode matches is different from a broker failure. For brokered
requests, compare `broker_failure`, `broker_status_class`,
`broker_redirect_count` and `broker_response_size_bucket`; these categories do
not reveal the host or path. The `original_count`, `returned_count`,
`filtered_count` and `truncated_count` fields show whether a provider returned a
large payload or whether TetoTV deliberately narrowed it to the requested
episode. Scheduler events show whether work ran, waited, timed out or was
cancelled independently of another provider.

Aniyomi diagnostics never include repository search terms, anime/manga titles,
episode or chapter names, provider URLs, request or response headers, cookies,
account values, exception messages, HTML, scripts, media URLs or media bytes.
Do not ask customers to add those values manually. Extensions that require an
interactive WebView/login, an unsupported native library, or a private/loopback
network target remain unavailable by design; their fixed stage and reason code
should make that limitation visible rather than presenting it as an empty
catalog.

After a native process crash the in-memory UI trail is gone; next-launch native
exit summaries and persisted redacted events remain the evidence. Very early
startup failures, abrupt power loss, a full storage device, and absent Android
callbacks can leave gaps. Capture explicit diagnostics soon after reproducing
a navigation problem. Physical Android TV testing is still required to confirm
the visible experience; passing automated tests is not a hardware guarantee.
