# Motion highlight investigation

Device: iPhone 13 Pro Max, iOS 17.3.1 (21D61), upstream24.
Measurements were read-only Frida 16.1.4 observations on 2026-09-08.
CPU percentages are measured from Mach task thread times; 100% is one CPU core.

## Observed before this fix

- Locked: SpringBoard about 1%; monitored icon processing/layout/filter paths idle.
- Unlocked, stationary Home Screen: SpringBoard baseline about 90%, backboardd about 141%.
- In that six-second interval, the icon pixel function, icon image getter, icon layout,
  and monitored filter update methods were not called.
- With Motion Highlights enabled, another six-second interval contained 199 motion ticks
  and 20,616 `applySpecularAngle:` calls. The motion callback came from CADisplayLink.
- After the user disabled only Motion Highlights: SpringBoard stationary baseline about
  0.34%, backboardd about 9.2%. A subsequent notification caused a temporary SB spike;
  that interval is not treated as a quiet baseline.

This identifies continuous motion-highlight layer updates as the dominant sustained
load in the observed configuration, rather than repeated icon bitmap conversion.
More glass instances amplify the old per-frame iteration and layer-commit work.

## Validation and remaining check

`python3.11 tests/test_motion_highlights.py` compiles the production update method
against instrumented native CAGradientLayers. It verifies that 20,000 repeated or
subpixel updates produce no extra setters, real motion keeps the same point geometry,
and angle wraparound, hidden/unhidden layers, new layers, and the 5/30 FPS policy work.

The device A/B results above validate the cause, not the performance of upstream25.
After installing, measure with Motion Highlights enabled in three states: stationary
Home Screen, gentle device tilt, and scrolling to another icon page. Check that newly
visible glass catches up and the upstream24 icon appearance is preserved.
