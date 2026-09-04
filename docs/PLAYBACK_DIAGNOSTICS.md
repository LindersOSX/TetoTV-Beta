# Playback diagnostics: investigating stutter

Implementation status: included in TetoTV Beta 2.0.71, including the MPV player
integration, bounded local storage, and explicit report export.
There has not yet been a real Android TV device validation run. Automated tests
do not establish native property availability, device overhead, or that the
reported lag is fixed. This patch adds diagnostic evidence, not a stutter fix.

The playback timeline explains how an attempt started, changed decoder policy,
fell back, or ended. It does not rate playback smoothness. Engine performance
samples add evidence about what happened during playback, but they are periodic
observations, not a recording of every video frame.

## Capture a useful report

1. Reproduce the issue on the affected device with the same feed and episode.
   Keep the source, quality, decoder setting, and display settings unchanged for
   the first comparison. Note the app build, approximate clock time, and whether
   the problem was visible stutter, a frozen picture, buffering, or audio drift.
2. Let the problem run long enough to include several samples when practical.
   Capture Diagnostics while it is lagging if accessible, or immediately after
   leaving playback. Do not start another episode before capturing the report.
   Use **Refresh** before **Copy full report** or **Send to support** if
   Diagnostics was already open. **Export full report** creates a local file.
3. If comparing builds or settings, use the same device and feed, note the one
   change being tested, and capture a separate report for each run. The timeline
   comparison does not verify that two sessions played the same media.
4. Share the report only when you choose to. **Send to support** asks for
   confirmation before submitting to the private support channel. Add the
   approximate problem time and the visible symptom so support can find the
   relevant samples; there is no need to send a stream URL or access key.

The monitor attempts native observations about every five seconds after MPV
opens, while the app is in the foreground. Periodic snapshots are saved about
every fifteen seconds. State transitions are observed promptly, with ordinary
transition writes coalesced to at most one per second. Attempt boundaries,
failures, completion, background flushes, and exit/handoff request a final or
forced snapshot rather than waiting for the periodic save. Terminal playback
stops periodic probing. Saves are best effort: the final seconds can be missing
after a crash, process kill, or storage failure.

Performance history is stored separately from the event ring so periodic samples
do not crowd out startup, fallback, and failure events. Retention is bounded to
the latest 24 attempt records within a rolling 48-hour window, ordered by their
latest saved observation. Repeated snapshots update the same attempt record;
this is not a log of every playback attempt.

### Actual-device validation checklist

1. On the affected Android TV, play the same feed for two to three minutes with
   unchanged quality, decoder, and display settings. Note the time and symptom
   of any visible lag; capture a baseline report before changing sources.
2. Pause, seek, and resume. If practical, briefly background and return to the
   app. Confirm playback and controls still behave normally; these transitions
   should not be counted as uninterrupted playback intervals.
3. Switch source or decoder, then leave playback normally. Confirm the report
   separates open attempts and retains the terminal snapshot. Do not interpret
   a new attempt as a continuation of the previous attempt's counters.
4. Open Diagnostics, refresh, and export the full report. Match `sessionId` and
   `attempt`; inspect timestamps, state, coverage counts, and available decoder,
   frame-drop, buffer, rate, and sync fields. Native availability varies by
   device, stream, and bundled MPV version: partial or omitted fields can be
   expected. Check that no media URLs, credentials, titles, or paths entered the
   performance records. Record device behavior and missing fields separately
   from any claim about whether the lag improved.

## Read the session outcome correctly

| Report value | Meaning | What it does not establish |
| --- | --- | --- |
| `working` (shown as **Started**) | Startup was observed when video dimensions became available. | A rendered video frame, correct cadence, or smooth playback. |
| `exited_after_start` | The player was left after startup was observed. | That the user was satisfied or the video was smooth. |
| `completed` | Playback reached completion. | That there were no stalls or dropped frames. |
| `failed` | A failure was recorded or inferred; inspect `finalReasonCode` and the timeline. | That every lagging session must have this outcome. |
| `in_progress` | No final outcome remains in the retained timeline. | That the app is still playing it now. |

The old reason code `decoded_video_observed` and its clearer replacement
`video_parameters_available` describe the same video-parameter startup signal.
Neither is a rendered-frame callback. `playbackSessionOutcomeMeaning` carries
these explanations inside the report. Wire values and the
`playbackSessionComparison.working` key remain compatible with older reports.

The **Started vs Failed** cards select the newest matching outcomes. The
started side can be `working`, `completed`, or `exited_after_start`; it is not a
known-smooth control session. A failure can also be inferred from a nearby crash
or a later session superseding an unfinished timeline. Check the reason before
interpreting that classification.

## Match performance evidence to the right attempt

Start with the target entry in `playbackSessions`, using its `sessionId`,
timestamps, and timeline. Then inspect `playbackPerformance` records with that
same `sessionId` and the relevant `attempt`. A retry or source/decoder fallback
can create a new attempt, so do not combine counters across attempts. These IDs
are local correlation identifiers, not media titles or source identities.

Check the record and sample timestamps against the time the problem happened.
The newest saved record is not automatically the session you meant to inspect,
and a record's latest observation can be a paused or exiting state. The timeline
and performance history have separate capacity limits; a performance record can
outlive some associated timeline events. Missing history or unavailable engine
properties mean **unknown**, not zero drops or successful playback.

`playbackPerformanceSchema` identifies the performance payload and
`playbackPerformanceWindow` describes its retention. Use the samples and summary
together: a summary is useful for spotting changes, while samples show whether
those changes coincided with buffering, pausing, seeking, or startup.

The window's `droppedOutsideWindow` and `droppedForCapacity` count records pruned
since diagnostics storage was created (`dropCountScope`), not losses occurring
only within the current 48 hours. `retainedCount` describes records actually
included now. Export's `droppedForExport` counts additional input records omitted
from that export; it is not a count of dropped frames or an estimate of missing
sessions. `invalidSnapshotCount` and `storageUnavailable` disclose rejected
stored data or unavailable storage, rather than silently implying an empty,
healthy playback history.

Generic event export has separate `diagnosticEventExport` coverage metadata:
`availableCount`, `exportedCount`, and `droppedForExport`. A compact report retains
the newest generic events (up to 50); if a pathological oversized report needs
the final fallback, it can omit generic events and declare that omission while
preserving the bounded performance records and summaries. Do not assume the
generic event list and performance history have identical coverage.

### Summary and sampling coverage

Each attempt retains its latest six observations. Transition observations can
replace periodic samples in this ring. `sampleCount` counts all accepted
observations for the attempt; `droppedSamples` counts observations no longer
retained in the ring, **not dropped video frames**. Summary totals can therefore
cover more observations than the six visible rows.

Counter fields such as `droppedFramesDelta` sum only comparable observed
intervals. Both endpoints must be playing, in the foreground, and not seeking;
missing state is excluded. Missing counters, counter resets, invalid samples,
non-increasing elapsed time, and gaps longer than 30 seconds break continuity.
A context-only transition observation also prevents a counter delta from being
inferred across it. `activeIntervalCount` counts eligible intervals, while each
counter's `ObservedIntervals` field counts the subset with both counter values.
An omitted delta means unknown; an observed delta of zero means only that no
increase was measured in those covered intervals. Buffering and HUD visibility
remain in the observations so they can be correlated with the symptom.

Summary codec, decoder, dimensions, and refresh-rate fields are the latest
available observations from the attempt. They can precede its final paused or
exiting observation and are not a fresh engine query made when the report is
opened. `videoParametersAfterMs` measures the startup parameter signal, not a
first rendered frame. `firstPositionAdvanceAfterMs` is an observed position
change, not proof that the corresponding picture reached the display. Missing
startup timings are not replaced by zero.

`bufferingEvents` and `bufferingTotalMs` cover eligible observed buffering,
including startup. `rebufferEvents` and `rebufferTotalMs` count buffering
segments that began after natural position advancement was observed; video
parameters alone do not end startup. These totals exclude pause, seek, and
background operation and do not infer time across long observation gaps.
`userSeekCount` records user seek commands, not automatic resume restoration or
watch-party synchronization, and does not by itself confirm a seek succeeded.

## Distinguish the evidence

- **Decoder policy vs active decoder:** `hardware_adaptive`, `hardware_direct`,
  and `software_compatibility` describe the selected policy. They do not prove
  that hardware decoding actually engaged. Use the sampled engine's active
  hardware-decoder and decoder fields when available. Device codec capabilities
  only describe what the device advertises, not what this stream used.

  MPV's `hwdec-current`, mapped to `activeHwdec`, reports the active path;
  `no` means software, while an unavailable property remains unknown.
  See the [official MPV property reference](https://mpv.io/manual/stable/).
- **Video counters:** rising decoder/output drop counters during steady
  playback are useful evidence of missed video work. They are engine counters,
  not an end-to-end measure of every frame visible on the TV. Seek, reopen, and
  engine resets can break continuity; do not subtract across a reset or attempt
  boundary. A zero increase in available samples does not prove perfect pacing.

  `mistimedFrames` and `delayedFrames` are display-sync-specific counters, with
  the latter based on an estimate, not a precise physical-display measurement.
  See the [MPV counter definitions](https://mpv.io/manual/stable/).
- **Buffering and position:** repeated buffering, low buffer availability, or
  a position that stops advancing while playback is requested can help narrow
  the issue. Check pause and seek state before calling it a stall. These signals
  alone cannot distinguish the network, source, decoder, or display as the cause.
- **Input I/O rate:** `inputBytesPerSecond` maps MPV's `cache-speed`, an estimate
  of bytes read from the underlying I/O layer. It is not measured connection
  bandwidth or a network speed test. `bufferSeconds` is an approximate demuxer
  buffer duration and can be unreliable or unavailable even when data is
  buffered. See the [MPV cache-property definitions](https://mpv.io/manual/stable/).
- **Timing and sync:** video-rate estimates and audio/video sync measurements
  are observations, not necessarily the content's intended rate or physical
  display delivery rate. Interpret them with the state and sampling interval.
- **Flutter UI timings:** `recentFrameTimings` contains `slow_frame` durations
  from Flutter `FrameTiming.totalSpan` greater than 20 ms. The slowest callback
  samples are coalesced and normally saved at most once every five seconds.
  This measures slow app-interface frames, not video FPS, decoder drop counts,
  or all rendered UI frames. Do not turn the number of rows into a video drop
  percentage. `recentFrameTimingMeaning` includes the metric's interpretation;
  `recentFrameTimingWindow` describes its retention.

Compare multiple observations around the reported lag. For example, increasing
video drops without buffering points to a different investigation than repeated
buffering with no available video counters. Neither pattern alone proves a root
cause, and display judder can exist without a reported engine drop.

## Privacy and limits

New performance records contain only bounded technical fields: local session
correlation, timestamps, state, decoder details, counters, and numeric
measurements. Media titles, episode names, URLs, paths, account identifiers,
credentials, headers, and access keys are not included in these records.
Performance diagnostics are stored locally; this change does not add automatic
uploading or change existing automatic-reporting behavior. Export/copy and the
confirmed support-send flow remain explicit user actions.
Treat the report as private: even without media identity it contains device and
usage timing information.

Only fixed, optional technical properties are queried; unknown or unsupported
values remain absent rather than being replaced with healthy-looking zeros.
The monitor allows at most four outstanding property requests and uses bounded
Dart waits (normally 200 ms per property within a 750 ms probe budget). A Dart
timeout cannot preempt a synchronous native MPV call, so these deadlines do not
guarantee a maximum native-call duration or zero playback overhead. No
observation-triggered decoder changes or other recovery actions are added by
this monitor. Actual-device testing is still required.

The report is intentionally bounded and privacy-filtered. Missing properties,
retention gaps, sample gaps, and unsupported engines limit conclusions. For a
stutter investigation, a **Started** result is the beginning of the evidence,
not the conclusion.
