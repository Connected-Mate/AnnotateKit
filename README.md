# AnnotateKit

**Tap-to-annotate your running iOS app, and hand the result straight to an AI coding agent.**

Web developers have [Agentation](https://www.agentation.com/): click any element in the browser, write a note, and get structured markdown an agent like Claude Code or Cursor can act on. Native iOS apps had no equivalent — describing UI feedback to an agent means typing "the blue button under the second card, no, the other one…".

AnnotateKit closes that gap. It overlays a small floating pill on your Debug builds. Tap it, tap any element on screen, type a note. Each annotation captures:

- the **accessibility element** under your finger — label, `accessibilityIdentifier`, value, traits, frame (the iOS equivalent of a CSS selector),
- the **nearby visible texts** — ready-made grep hints to find the view in source,
- the **UIKit view chain** under the tap,
- a best-effort **screen title**,
- a **screenshot** with the tap point marked.

Then one button compiles everything into a paste-ready markdown prompt.

```markdown
# UI feedback — MyApp

Annotations captured in-app with AnnotateKit. App v2.0.2 (9), iPhone iOS 26.2 — 2 item(s).

## 1. This button is too small and overlaps the card below
- **Screen**: Recordings
- **Element**: Button “Start recording” — accessibilityIdentifier `record-button`
- **Traits**: button
- **Element frame**: (24, 610) 44×44 pt
- **Tap**: (46, 632) on a 393×852 pt screen
- **Nearby texts**: “Recordings”, “Today”, “3 items”
- **UIKit views**: `CGDrawingView < _UIGraphicsView < _UIHostingView`
- **Screenshot**: `/…/AnnotateKit/capture-1a2b3c4d.png`
```

## Installation

Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/Alex-Connected-Mate/AnnotateKit", from: "0.1.0")
]
```

Or in Xcode: **File → Add Package Dependencies…** and paste the repo URL.

Requirements: iOS 17+ (Mac Catalyst supported), Swift 5.9+.

## Usage

One modifier, near the root of your app:

```swift
import AnnotateKit

struct RootView: View {
    var body: some View {
        MainTabView()
            .annotationOverlay()
    }
}
```

That's it. **In Release builds the modifier compiles to an inert `self`** — no debug UI, files, or logs can ship to TestFlight or the App Store, so you can leave it in place permanently.

Optional configuration (call once, e.g. in `App.init`):

```swift
AnnotateKit.configure(
    appGroupIdentifier: "group.com.example.myapp", // store files in the App Group container
    logSubsystem: "com.example.myapp"              // OSLog subsystem for the JSON stream
)
```

## Getting annotations to your agent

Three transports, use whichever fits your loop:

1. **Pasteboard** — the annotation list has a *Copy prompt* button. On a device, Universal Clipboard forwards it to your Mac: copy on iPhone, paste into your agent.
2. **Live log stream** — every saved annotation is also emitted as a single OSLog line, `ANNOTATEKIT {json}` (category `AnnotateKit`). If you already stream device logs while testing (e.g. `xcrun devicectl` + `log stream`), annotations arrive on your Mac in real time, no copy-paste:
   ```bash
   log stream --predicate 'category == "AnnotateKit"' --style compact
   ```
3. **Files** — `annotations.md` (the same prompt), `annotations.json` and the screenshots are written to `Documents/AnnotateKit/`, or to the App Group container if you configured one. With Mac Catalyst that container is a plain folder on disk (`~/Library/Group Containers/<group>/AnnotateKit/`) an agent running on the Mac can read directly.

## How it works

- A **passthrough `UIWindow`** sits above the app (the classic debug-tool pattern). Its `hitTest` only claims touches on the pill, in annotation mode, or while one of its sheets is open — the rest of the time your app behaves as if it weren't there.
- On tap, AnnotateKit walks the **accessibility tree** of the app's window and picks the smallest accessibility element containing the tap point (falling back to the nearest one within 44 pt). SwiftUI's runtime view internals aren't inspectable, but the accessibility tree carries the semantics that matter: labels, roles, identifiers, frames — and it's exactly what improves as you adopt accessibility best practices.
- Since labels are localized at runtime, the generated prompt reminds the agent to search your String Catalog / `.lproj` files when a literal doesn't appear in Swift sources.

## Limitations

- SwiftUI doesn't expose source locations at runtime, so unlike Agentation on the web (which reads React fibers) AnnotateKit can't point to a file/line — the grep hints and identifiers are the bridge. Adding `accessibilityIdentifier` to key views makes annotations sharper.
- Elements hidden from accessibility (`.accessibilityHidden(true)`, decorative views) fall back to the UIKit view-chain description.
- One overlay per window scene (the first scene wins on iPad/Catalyst multi-window setups).

## Credits

Inspired by [Agentation](https://www.agentation.com/) by Benji Taylor. Not affiliated.

## License

MIT — see [LICENSE](LICENSE).
