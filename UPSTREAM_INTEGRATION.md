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

The current blur path remains the default. The follow-up below adds an optional
system blur overlay; it does not replace the shader, change the material parameter
units, retune existing host defaults or import the upstream specular motion rewrite.
Classic/Enhanced modes and current motion frame/visibility limits stay.
The new host registry entries use Banana ratio/thickness units provisionally;
their visual tuning belongs to the renderer follow-up.

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
