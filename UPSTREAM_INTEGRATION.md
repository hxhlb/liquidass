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

`LiquidAssBackboardd/Tweak.mm` and `Shared/LGLiveBackdropView.m` remain identical
to the Banana base. This stage does not merge the upstream blur-pass replacement,
BezelRatio-to-BezelWidth migration, existing-host material retuning or specular
motion rewrite. Classic/Enhanced modes and current frame/visibility limits stay.
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
- Package identity/version and release/maintainer scripts.

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

No DEBs built, no device changes, no GitHub push or release in this stage. Before
release, test both modes and switching/disable/lock/unlock on iOS 15–18, with
LiquidAss alone, SpatialScene alone and both together. Verify depth ordering,
notifications, date/font controls, pull transitions and AssistiveTouch toggles.
