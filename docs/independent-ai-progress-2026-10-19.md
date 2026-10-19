# Independent follow-up: Linux ownership and local AI foundation

The Android freeze remains in force. No emulator/adb/install/export, deployment, public publishing or writes
to `build/android-game-preview` were performed. All diagnostics and fixtures used separate repository build
directories and isolated profiles. Existing v3 contains none of these new source changes.

## Linux display-object lifetime fix

An isolated current-source Linux stage reproduced the unmodded game's retained textures/text resources.
Inspection found 41 leaked display nodes absent from `FlashDisplayObject.off_tree`: objects that had never
entered a scene tree were not reliably registered through `NOTIFICATION_POSTINITIALIZE`.

`game/flash/display_object.gd` now registers instance IDs during base construction, retaining existing
enter/exit/predelete handling. A neutral regression **failed before** this fix and passes afterward. It checks
never-attached registration, actual orphan cleanup, preservation of in-tree objects and removal of freed IDs.
This supplements the previous mod reference-cycle teardown; it is not an eager free of detached live objects.

Evidence: `build/independent-linux-lifecycle-dyg7y86d/`:

- `baseline.log` / `baseline.json`: initial reproduction, including verbose engine diagnostics.
- `orphans.log`: tracked/untracked instance correlation and cleanup registry observations.
- `constructor-fix.log` / `constructor-fix.json`: after changing the staged display-object constructor,
  the 90-frame headless run exits 0 without the prior texture/text RID leak errors, but **40 resources remain
  in use at exit**. This is still a failed clean-shutdown gate, not a finished leak fix or rendered acceptance.

## AI provider foundation

Implemented opt-in Godot configuration, injectable provider client and bounded HTTP transport under
`game/src/integrations/ai/`. Contracts cover LM Studio chat, ComfyUI queue/history metadata and optional
AUTOMATIC1111 single-image responses. Disabled default, local/private roots only, explicit session LAN
consent, in-memory/environment Bearer credentials, no redirects/retries and authored dialogue fallback.

Neutral mocks cover provider routing, consent/revocation, bounds, failure responses, timeout, JSON/schema
errors, redirects, authentication headers and image-job states. Only a loopback mock server is run; no real
model or image generation takes place. No authored game dialogue, image assets or default gameplay was
replaced. See `local-ai-providers.md` for configuration and supported/unverified behavior.

## Review UI and platform configuration follow-up

The existing game now instantiates an optional Local AI review panel outside vanilla mode. It supports
validated non-secret profile persistence, session-only token entry and exact-LAN approval, explicit
connection checks, plain-text responses and bounded ComfyUI/AUTOMATIC1111 PNG previews. It pauses game input
while open and rejects stale responses; no action parser, authored dialogue or asset is modified.

Six-target plan/staging tooling and a manual Linux/Windows/macOS contract workflow were added. Installer
source supports verified desktop engine archives and opt-in broader templates. Future Android packaging
source supports an explicit networking flag for versions above frozen v3, separate output and final
manifest permission checks. These packaging changes were tested only as temporary preset text; no Android
SDK/tool, export, install or emulator was run. See [build boundaries](local-ai-builds.md).

Latest selected suite: **53 passed, 0 failures/errors/skips**, with ResourceWarning as error.
Evidence: `build/independent-ai-integration-nbb4is2m/report.json` and `tests.log`. These combine existing
tooling guards with neutral ownership, provider/UI and build-plan fixtures, not 53 real-server tests.
Six-target plan: `build/independent-ai-platform-plan-20261019/plan.json`; no game staged or exported.

## Not yet implemented or verified

- Real LM Studio, ComfyUI or AUTOMATIC1111 versioned smoke tests.
- Rendered game/UI acceptance, phone layout/focus and real-device approval/credential behavior.
- Approved asset import, gameplay dialogue replacement, cancellation or generation scheduling.
- Execution of the new Windows/macOS CI jobs; game exports and acceptance on all six targets.
- Phone builds, LAN connectivity, Android permissions/cleartext policy, background lifecycle or actual TLS setup.
- Full Linux leak closure, rendered functional/visual/audio acceptance or performance certification.

Next phase should validate the rendered UI and perform explicitly authorized real-server tests.
Phone/network/export work remains deferred to the owner
of the independent Android review. Do not broaden server binding or weaken TLS to get a connection.
