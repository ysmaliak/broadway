# Motion

## Reduce Motion

When Reduce Motion is on in System Settings, Broadway keeps one rule:

- Movement stops. Nothing slides, grows, shrinks, springs, bounces or scales. A thing that would have moved is at its new place or its new size at once.
- A fade of up to 0.2 seconds may stay. A fade changes only how see-through a thing is, never where it is.

So a surface may still fade in or out for a moment, and a picture may still fade into the next one. A window that changes size, a bar that slides in, a key that shrinks when it is pressed and a card that springs all change at once.

The code is `Motion` in `Sources/Search/Kit/Tokens.swift` and `Sources/Search/Kit/KitMotion.swift`:

- `Motion.reduced` says whether Reduce Motion is on. A test world sets it with the `motion.testReduced` setting.
- Every curve that moves a thing (`Motion.kitGlide`, `kitSettle`, `kitRoll`, `kitCover`, `kitQuick`, `kitEdge`, `kitSlide`, `kitFold`) is `.none` while it is on. Use one of them and the rule is kept for you.
- `Motion.reducedFade` is the 0.2 seconds.
- `Motion.staysUnderReduce(_:)` says whether one animation keeps the rule: a fade, or a change of opacity, of no more than `Motion.reducedFade`.

New code that animates without a kit curve asks `Motion.reduced` itself and changes at once when it is on, as `CallShape.glide` does for the call window.

The loading ring (`RingView` in `Sources/Search/TabBar.swift`) keeps the rule too. It turns while a tab or a live folder loads, and while Reduce Motion is on it stands still as an open arc and comes and goes without a fade.

The unit tests are `Tests/SearchTests/ReduceMotionTests.swift`. The probe is `python3 Tests/float_review_shots.py --still`: it turns Reduce Motion on in a test world, draws every floating glass surface the bench has, and fails if any layer of one holds an animation that `Motion.staysUnderReduce` refuses.
