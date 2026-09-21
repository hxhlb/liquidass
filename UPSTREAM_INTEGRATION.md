# Upstream 0.1.1-2b integration — stage 1

Base: Banana `1baa9d6` (`0.1.1b+banana33`).
Upstream: `9b7c5eb`, including post-release depth-container fix `5784d59`.
Branch: `iya/upstream-0.1.1-2b-dual-clock`.

## Included

- AssistiveTouch, volume HUD and ringer pill surfaces with reachable settings.
- Upstream alert/context-menu, Control Center, keyboard, tab bar, folder-transition
  and RTL control changes, retaining Banana-specific guards and restoration.
- AltList app exclusions. Framework loading follows Rootless/RootHide paths and
  reports an unavailable dependency without preventing the settings page opening.
  Legacy executable-name entries survive picker saves and still match processes.
- Upstream localization additions and settings navigation changes.
- Clock mode menu (`Clock.RenderingMode`) using the requested Chinese labels:
  **原生修改** (`native`, default) / **自定义层** (`custom`).
  Both modes share variable font and date-format controls; FPS controls the
  motion display link. Unknown mode values fall back to `native`.

## Clock integration

Native mode retains Banana's existing path: native backdrop/mask when available,
including iOS 18 capture scale, with the previous custom fallback on legacy hosts.
Selecting native mode on iOS 15 does not invent a missing system backdrop API.

Custom mode follows upstream's container-sized glass and glyph mask, prioritizing
`CSProminentDisplayView`, then `CSCoverSheetView`, and legacy host's superview.
It uses the upstream obstacle-aware variable-font rendering and pull blur while
leaving the source label's font alone. It does not create a wallpaper depth mask.
Depth occlusion depends on the actual wallpaper/layer hierarchy.

Switching mode restores font/frame/clipping, native filter order/capture scale,
portal opacity and source visibility, then discards the previous custom glass,
blur and masks. Deferred attachment invalidates the clock signature only outside
an active apply, to avoid duplicate source text and notification-driven loops.
Pull detection uses cover-sheet movement, avoiding a clock container's resting
inset. The motion display link still stops after its tracking deadline, even if
an offscreen cover sheet retains a translated frame and window.

## Explicitly deferred renderer work

The current blur path remains the default. Optional system blur and the Enhanced
bezel/geometry follow-up are described below. Classic shader calculations and tuning remain intact. Enhanced now uses the raw
upstream default table (see banana37). The upstream specular motion rewrite is still deferred. Filter-registration
ordering is included in the banana37 test described below. Classic/Enhanced
modes and current motion frame/visibility limits stay.

Do not import upstream `lgClearAccessibilityFiles` unchanged: it removes the
persisted backboardd crash guard and hook-probe files before the guard is checked.
Retain iOS 18 two-Shape forwarding/scanning, Rootless CFPreferences and RootHide
paths when that follow-up begins. As this merge records upstream ancestry, use
an explicit `b401069..9b7c5eb` source comparison for the deferred renderer work;
a later ordinary merge will not replay those intentionally retained hunks.

## Preserved Banana behavior

- iOS 15 clock font ownership and global-icon provider cache fixes.
- banana33 asynchronous UISwitch enabled-state synchronization and slider guards.
- Existing widget/icon/RWB implementations, including the Maps rollback.
- Existing defaults, cover-sheet bezel-ratio controls, batched preference writes,
  motion warning, Dynamic Island and iOS 26 icon settings.
- Package identity and release scripts; the installer change is recorded below.

AssistiveTouch hooks are initialized only under both master and surface enable
flags. A flag change relaunches assistivetouchd so native layers are reconstructed;
observers remain active when launched disabled. The surface Apply action keeps
upstream's explicit AssistiveTouch restart behavior.

## Validation boundary

- iOS SDK syntax-only checks of all 24 changed Objective-C/Logos translation units.
- RootHide arm64e syntax checks for the clock and AltList loading path.
- Nine regression suites passed: existing ownership, switch, widget, motion and
  render-interface checks plus the two integration suites below.
- New Foundation-backed tests: clock default/container/restoration/cleanup and
  settings mode menu/exclusion migration. These execute selected production code
  with UI doubles; they are not device rendering tests.
- Localization plist/duplicate-key checks and unchanged-file checks for deferred
  renderer, widget/icon/RWB and release/installer sources.

The local banana34 test packages have now been built and validated (see below).
No device changes or GitHub publication. Before release, test both modes and switching/disable/lock/unlock on iOS 15–18, with
LiquidAss alone, SpatialScene alone and both together. Verify depth ordering,
notifications, date/font controls, pull transitions and AssistiveTouch toggles.

## Optional blur comparison (Enhanced only)

Settings > More Options > Blur implementation (`Renderer.BlurMode`):

- `current` / 当前方式: default, preserving the existing Enhanced Metal blur pass.
- `system` / 系统模糊层: upstream-style native Gaussian overlay, with the same
  per-surface Blur controls. It uses the shared upstream `LGAdjustableBlurView`
  so the preference bundle has the implementation too; shape frames and rounded
  clipping follow the glass surface. Zero blur removes the overlay.

The menu stays visible but disabled under Classic. Profile selection refreshes
its enabled state, and stale menu actions also check eligibility. Switching back
to Classic preserves the stored blur choice; it never activates that choice in
Classic. Enhanced must be active after the normal renderer-profile restart before
system blur runs. Once Enhanced is active, the two blur choices use the existing
parameter-reload notification flow without an additional restart requirement.

Each standalone glass filter uses an explicit `.systemBlur` variant while its
view supplies the native overlay. Backboardd skips the owned Metal blur only for
those variants, keeping host/radius/dark/refresh routing intact. This avoids using
a global backend toggle which could disagree with a view in another process.
Native clock `.nativeMask` filters never get the suffix and retain their current
behavior; the custom clock layer supports the comparison. Existing independent
material blur layers (for example AssistiveTouch/button materials) are preserved.

Validation: production-code tests cover Enhanced UI/runtime gates, a pending
profile restart, invalid/default selections, radius limits, overlay reuse/removal
and geometry, all 2,092 standalone filter variants and native-clock isolation.
Rootless arm64 and RootHide arm64e syntax checks passed for the four changed
translation units. Existing motion, renderer ABI, clock and settings regressions
passed. Rootless/RootHide DEBs are now available for testing; device visual and
performance validation remains pending.

## banana34 local test packages

Version: `0.1.1b+banana34`. Both schemes built with `release.sh` and the matching
Theos checkout, including arm64 and arm64e slices in all four Mach-O binaries.
Package checks passed for identity/version, architecture, Rootless/RootHide
layout and linkage, font resource, new localized selectors, changelog and POSIX
postinst syntax. The installer resolves commands through PATH for apt/dpkg and no longer terminates
backboardd. Restart userspace manually after installation.

Artifacts: `packages/iya.iapple.liquidass_0.1.1b+banana34_iphoneos-arm64.deb`
and `packages/iya.iapple.liquidass_0.1.1b+banana34_iphoneos-arm64e.deb`.
Validation records/checksums: `packages/release/v0.1.1b-banana34/`.
Matching symbols: `packages/symbols/banana34/{rootless,roothide}/`.
No GitHub push, tag, release or device installation has been performed.

## banana35 HUD compatibility fix

iOS 17.3.1 runtime capture showed that `SBElasticSliderMaterialWrapperView` and
`SBElasticVolumeSliderView` do not exist. The actual view is `SBElasticSliderView`
under `SBElasticVolumeViewController`, with `_elasticContentView`, base/capture
materials, a separate `_backgroundView`, and a distinct `_backgroundFillView`.
The fallback is registered only when the modern wrapper is absent, and checks the
volume controller ancestry so brightness/Control Center sliders are excluded.
Only the three background materials and shadow are suppressed, after filter
attachment. The value clipping view, fill and glyphs remain intact. Native hidden
states are restored on disable/detach.

AssistiveTouch crash `assistivetouchd-2026-09-16-104258.ips` matched banana34's
RootHide arm64e UUID `7F4DF39C-FC6F-320A-9622-E97EAD1DC730`: offsets `0xdea4` and
`0x10be8` map to `ASSHeldGlassView initWithFrame:` and `HNDRocker didMoveToWindow`.
The exception originates in `_UIGraphicsBeginImageContextWithOptions` when the
initial glow diameter is zero. Invalid dimensions now return nil; usable layout
creates the missing glow and subsequent unchanged layouts reuse it. The regression
fixture fails on banana34 and passes on this fix.

`test_assistive_glow.py` and `test_volume_hud.py` pass. Actual fixed-package
visibility, touch behavior and glass appearance remain pending device validation.

### banana35 device follow-up

The user confirmed the volume HUD now works on iOS 17.3.1 RootHide. AssistiveTouch
subsequently returned. The user initially reported no glass effect while idle,
but later confirmed that pressing/dragging shows it, matching upstream behavior. Both system AssistiveTouch and the
LiquidAss surface preference read enabled. The live rocker has 60x60 bounds and
a valid generated glow image; no newer AssistiveTouch crash report was observed.
The launch service retains prior crash/backoff records, so the exact delayed
visibility recovery trigger has not been proved.

Idle inspection shows the custom glass filter attached, but its parent
`ASSHeldGlassView` is hidden with alpha 0. Upstream explicitly shows that container
only during press/drag and hides it on release. The user subsequently confirmed
this press/drag effect. Constant idle glass was offered but has not been requested.
Diagnostics so far are read-only; no device preferences or view properties were
changed and no processes were restarted by the diagnostic tools.

## Enhanced bezel width and geometry (banana36 test build)

- Classic retains its previous ratio calculations and shader behavior. The shared
  CPU/Classic/Enhanced uniform declaration gains the same border-width field.
- Enhanced gains per-surface `BezelMode`: compatible ratio or fixed width in pt.
  An explicit mode wins; otherwise a saved width selects points, a saved ratio
  keeps compatibility, and fresh surfaces use upstream point defaults. Dynamic
  Island keeps its legacy default because upstream supplies no corresponding host.
  No preferences are destructively rewritten. Both keys remain exportable.
- The mode/point slider is visible only under Enhanced; the inactive unit's slider
  is disabled. Returning to Classic always uses the original ratio, retaining the
  Enhanced choice. The clock keeps its existing dedicated mask-width path.
- Fixed widths use upstream's `scale * 2` render conversion, capped at half the
  surface's shortest side. CoverSheet uses its shared pixels-per-point value when
  available. Actual cross-device visual scaling still needs device validation.
- Enhanced shader ports upstream keyboard bottom extension/refraction suppression,
  cover-sheet top refraction suppression, hard subshape clipping and border lift.
  The keyboard filter uses its shape radius; TabBarSelection receives full capture
  scale under Enhanced. Existing tint, thickness, zoom and highlighter tuning stay.

Validation: legacy/point precedence, pixel scaling/caps and settings gate tests;
unchanged Classic shader body and pre-existing host defaults; matching uniform
fields/offsets; both real Metal shader compilations and GPU edge/alpha/border tests.
The source integration passed these checks before packaging. The subsequent
banana36 local test build is recorded below; no device settings were changed.

## banana36 local test packages

Version `0.1.1b+banana36`, containing the Enhanced bezel/geometry work from
`ae1905e`. RootHide and Rootless were built sequentially with their respective
Theos installations. Both packages passed metadata, four universal-binary slices,
symbol UUID, loader path, font, localized clock/blur/bezel control, version,
changelog and postinst checks. The installer does not terminate backboardd.

Artifacts: `packages/iya.iapple.liquidass_0.1.1b+banana36_iphoneos-arm64.deb`
and `packages/iya.iapple.liquidass_0.1.1b+banana36_iphoneos-arm64e.deb`.
Checksums/validation: `packages/release/v0.1.1b-banana36/`.
Symbols: `packages/symbols/banana36/{rootless,roothide}/`.
Install manually and restart userspace. Select Enhanced and complete its profile
restart before evaluating the new geometry. Device appearance remains unverified.
No push, tag, GitHub release or automatic installation was performed.

## banana37 independent engine parameters

The main acceptance criterion is independent tuning: editing or resetting one
engine must not overwrite the other engine's material values.

- Classic keeps existing unprefixed keys and Classic defaults. Existing large
  legacy thickness values retain their previous interpretation at preference
  reload only; there is no thickness conversion in the rendering loop.
- Enhanced uses `Enhanced.<key>` and the literal upstream material table in
  `Shared/LGUpstreamHostDefaults.h` (9b7c5eb). No old-key fallback and no cross-engine
  multiplication/division. AssistiveTouch thickness is 18, Volume HUD is 280.
  Dynamic Island has separate Enhanced defaults because upstream has no such host.
- The intermediate banana36 mixed-unit selector is retired. Classic uses its
  ratio units; Enhanced uses upstream point widths. Enhanced defaults to system
  blur, with the optional renderer-blur choice retained in its own group.
- Thickness, refraction, index, tints, blur, dispersion, specular parameters,
  geometry, quality, motion settings and clock FPS are independent. Master and
  surface enable flags, font/date controls, clock implementation and icon modes
  remain shared.
- Settings controls write physical keys for the selected group. Switching the
  engine rebuilds those controls after the queued preference commit completes.
  Runtime selection stays latched until restart, matching the backend profile.
- Presets always export both physical groups. Old unprefixed presets update only
  Classic material settings, even while Enhanced is selected. Surface reset uses
  that page's current physical keys; the explicit global Reset All still clears
  both groups and shared controls.
- Classic clock material inheritance/adaptive tint remains Classic-only; Enhanced
  uses its own clock material/tints. Enhanced also uses upstream Fresnel strength
  and tab-selection zoom rather than Classic overrides.

Validation: production-code tests cover every scoped key, runtime profile latch,
Classic/Enhanced independent edits, upstream default equality, actual backend
reload values, both-group preset round trips and isolated surface reset. Existing
widget, icon, clock, switch, motion, Metal geometry, AssistiveTouch and HUD tests
pass. Device visual and thermal validation is still pending; no heat reduction
is claimed from removing a few arithmetic operations.

### banana37 filter registration ordering

Gaussian hooks are prepared once after their context/slots are valid, before
waiting for QuartzCore's filter table. Custom atoms are still registered only
after that table is ready. If the Gaussian context itself is pending, registration
retries after 250 ms. Resolved edge/render slots are retained after hooking: a
retry must not scan the now-patched function bodies or install duplicate hooks.
The clone path still waits for the table before allocating its descriptor.

`test_filter_registration.py` executes the production registration body with
controlled delayed context/table readiness, scanners that reject already-hooked
code, invalid slots/symbols, hook failures and the iOS 14 fallback. It verifies
single installation/registration and preserved ordering. `test_render_compat.py`
still passes the iOS 14/15–17/18 forwarding checks. The upstream broad accessibility
file cleanup is not imported; crash/probe protection remains intact.

Material defaults are implemented in the independent Enhanced table, but final
acceptance remains pending the user's device test. Dynamic highlights retain the
existing Banana optimization (30 FPS active / 5 FPS idle, unchanged-angle and
visibility suppression); the upstream single-gradient/idle-pause rewrite is not
part of this build.

### banana37 combined local artifacts

Both Rootless and RootHide were rebuilt after the registration-order change.
The delivered banana37 artifacts include parameter isolation and registration
ordering together. All four binaries contain arm64 and arm64e; symbol UUIDs,
loader paths, version, localization/resources, font and postinst checks passed.
The installer still does not terminate backboardd. Checksums/validation records
are in `packages/release/v0.1.1b-banana37/`, and matching symbols are under
`packages/symbols/banana37/{rootless,roothide}/`. No GitHub push/tag/release or
remote device changes were performed.
