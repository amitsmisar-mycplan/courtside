# Courtside — Phase 1

Import a game video, tap through it when something good happens, get clips. On-device only.

**Status:** build steps 1–5 done; step 6 (recording) waiting on a device. See [docs/status/progress.md](docs/status/progress.md).

## Run

Open `Courtside/Courtside.xcodeproj` in Xcode, pick an iPhone simulator, Run. Tests: ⌘U, or

```
xcodebuild -project Courtside/Courtside.xcodeproj -scheme Courtside -destination 'platform=iOS Simulator,name=iPhone 17' test
```

No third-party dependencies. New files dropped into `Courtside/Courtside/` are picked up automatically.

## Layout

```
Courtside/
  Courtside.xcodeproj
  Courtside/          app source (App, Models, Import, Processing, Playback, Views)
  CourtsideTests/     unit + export tests
docs/
  spec/               founder's Phase 1 spec
  decisions/          numbered records of deviations from the spec
  status/             progress and open questions
  testing/            Simulator results, device acceptance checklist
```
