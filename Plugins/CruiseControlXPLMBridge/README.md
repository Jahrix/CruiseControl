# CruiseControl XPLM Bridge

This is a source-only Phase 10 safety bridge. It is not bundled with the macOS
app and must be built with the official X-Plane SDK for each required macOS
architecture before installation.

Install the resulting plugin bundle at:

`X-Plane 11/Resources/plugins/CruiseControlXPLMBridge/` or
`X-Plane 12/Resources/plugins/CruiseControlXPLMBridge/`

The source uses only SDK APIs available to both major versions, but it treats
each exact simulator build and plugin load as a separate unverified session.
It does not grant write permission merely from `XPLMCanWriteDataRef`.

## Build and install (macOS)

1. Download the official X-Plane SDK that matches the simulator major version
   you will test and set `XPLANE_SDK` to its extracted directory. Do not use
   private headers copied from another plugin.
2. From this directory, build a native plugin with the SDK headers and
   framework. For an Apple-silicon-only XP11 test, for example:

   ```sh
   clang -dynamiclib -arch arm64 \
     -I"$XPLANE_SDK/CHeaders/XPLM" \
     CruiseControlXPLMBridge.c \
     -F"$XPLANE_SDK/Libraries/Mac" -framework XPLM \
     -o mac.xpl
   ```

   Build a separate `x86_64` slice (or a universal binary) when the installed
   simulator requires it. Use the SDK's documented macOS plugin packaging
   convention for the simulator version in use.
3. Create `Resources/plugins/CruiseControlXPLMBridge/` inside the exact
   X-Plane installation being tested and place the compiled plugin there using
   that packaging convention. Restart X-Plane; a plugin reload creates a new
   unverified session.
4. Start CruiseControl and confirm the app and bridge are both using loopback:
   telemetry remains on UDP `49005`; this bridge listens only on UDP `49006`.
   The bridge status file is written to CruiseControl's Application Support
   folder. A fresh status should show `lod_candidate=true`, but
   `lod_write_supported=false`.
5. In CruiseControl's Adaptive LOD/setup card, choose **Verify Adaptive LOD
   Bridge** once while parked with a stable view. Do not change X-Plane
   settings during the brief transaction. Success requires the UI to say
   **Verified for [exact build], plugin session [ID]**. It must remain
   unavailable if the UI reports failure or an incomplete identity.
6. Restart/reload the plugin and repeat. The previous result must become
   invalidated; verify that X-Plane's original LOD is restored after the test.

Repeat the same procedure in XP12. XP11 proof never authorizes XP12, and a
new simulator build or plugin session always requires a new verification.

Protocol, on loopback UDP port 49006:

`CCLOD/1 VERIFY <controller-lease> <nonce> <sequence>`

`CCLOD/1 SET <controller-lease> <nonce> <sequence> <lod>`

Terminal responses are:

`CCLOD/1 RESULT <plugin-session> <nonce> <sequence> <result> <requested> <observed> <state>`

The plugin executes all XPLM work from its flight-loop callback. A verify
operation performs a 0.01 bounded probe, requires three matching readbacks,
restores the captured value, and requires three more matching readbacks. Any
failure locks out the current session. This remains evidence about an
unsupported private dataref, not official Laminar support.
