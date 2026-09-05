# Native crash report DaRWxCIG-eed40dG-wrw

## Evidence

The supplied report is from TetoTV 2.0.69 (410046), an arm64 phone running Android SDK 36. Android recorded a foreground native SIGSEGV/SEGV_MAPERR, labeled as a null-pointer dereference, roughly 76 seconds after startup. It predates the optional Media3 implementation.

Only 64,000 bytes of the tombstone were captured, explicitly marked truncated. The reported frames are an event-loop/wait stack involving libc, libutils, libandroid and libflutter; binary build IDs were redacted. This does not establish that Flutter, MPV, a video stream, or any particular app action caused the crash.

## Confirmed reporting defects repaired

- The collector could substitute a different thread's stack when the faulting thread was missing from its limited scan. It now selects the exact faulting thread or explicitly reports it missing.
- Native capture now has a bounded 1 MiB ceiling and scans the bounded protobuf data without the old first-eight-thread limitation. Truncation, scan limits and malformed data are explicit.
- Malformed length-delimited input stops parsing instead of treating its interior as unrelated top-level fields.
- Binary-derived ELF build IDs survive privacy filtering as reversible four-hex groups, and the technical fingerprint has a non-secret field label. Generic token, URL and personal-data redaction remains enabled.

Native parser regressions include late faulting threads, large ignored fields, missing/truncated traces and malformed input. The Dart reporter regression verifies that the technical fingerprint/build ID survive while credentials and private URLs do not. Automatic reporting still requires opt-in.

## Remaining uncertainty

These changes fix misleading/incomplete diagnostics, not a proven SIGSEGV trigger. The existing report cannot be repaired retroactively or safely attributed to a specific library. A fresh occurrence with the updated collector and the matching build's symbols is needed before claiming that the underlying native crash is fixed.
