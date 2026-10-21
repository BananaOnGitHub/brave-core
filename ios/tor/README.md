# BraveTor

Embedded Tor runtime and isolated iOS browser prototype.

See [the implementation plan and validation matrix](../../docs/ios_tor_prototype.md)
for usage, architecture, dependency provenance, and limitations.

`swift test` on macOS validates the actual embedded Tor control connection with
networking disabled. The independent iOS harness is in `Harness/`.
