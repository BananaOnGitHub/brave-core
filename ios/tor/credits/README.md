# Tor credits

The iOS GN defaults enable `generate_about_credits`, including local builds.
`script/brave_license_helper.py` registers the two metadata directories here
with Chromium's standard credits generator. Their license files are also
packaged as local Swift package resources; opening credits needs no network.

`embedded/README.chromium` references the existing Tor.framework notices for
Tor, OpenSSL, libevent, liblzma, and the framework distribution.
`transports/README.chromium` references the IPtProxy, Go runtime, Lyrebird,
Snowflake, DNSTT, and transitive module notices.

After updating IPtProxy, update the pinned revisions and Go version in
`generate_transport_notices.py`, then run it with Python 3. It downloads only
source manifests, licenses, and module archives; it does not execute them.
Review the generated diff. The inventory intentionally covers the complete
upstream module manifest, including tooling and transports Brave does not
enable, rather than trying to infer binary license coverage from UI choices.
Archive URLs, versions, and SHA-256 hashes are recorded with each module.
No downloads or generation are performed at application runtime.

After rebuilding the native core and application, verify `brave://credits`
shows the normal generated list, and expand both the Embedded Tor and IPtProxy
entries. Check that full license text is visible while offline.
