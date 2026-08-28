# Security policy

## Supported versions

Only the latest completed Beta release receives security fixes. No Public APK
is currently published. Older release history and locally built variants are
not supported security targets.

## Report a vulnerability privately

Use the repository's **Security** tab and choose **Report a vulnerability** to
open a private GitHub Security Advisory. Include:

- the affected version and device type;
- a concise description of the security boundary that fails;
- reproducible steps or a minimal proof of concept;
- expected and observed behavior; and
- potential impact, without including another person's private data.

Do not open a public issue for an unpatched vulnerability, credential, signing
key, private pairing capability, or SDK archive. Do not test against another
person's account, room, server, or device without authorization.

## Scope

Good-faith reports may cover the Android app, updater validation, setup broker,
Watch Party, diagnostics pipeline, extension sandbox/network controls, secure
storage, or release supply chain. Availability problems in an independent
third-party service, content disputes, and unsupported modified builds are not
security vulnerabilities in TetoTV unless they demonstrate a concrete TetoTV
boundary failure.

The maintainer will acknowledge a complete report, investigate it, coordinate
a fix and disclosure window when appropriate, and credit the reporter if they
want to be named. No response-time or bounty promise is made.
