# 0010 — Bundle identifier `com.awave.courtside`

**Status:** Accepted · 2026-10-07 (founder chose "AWAVE")

The placeholder `com.example.courtside` can't be signed for a device. The app is now `com.awave.courtside`
(tests: `com.awave.courtsideTests`). The display name stays "Courtside" (still a working name per the spec).

Changing a bundle ID later means a different app to iOS: existing installs and their data don't carry over. Fine now
(nothing shipped), but settle the final ID before the first TestFlight build.
