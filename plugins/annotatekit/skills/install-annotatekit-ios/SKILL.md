---
name: install-annotatekit-ios
description: Install and configure AnnotateKit in an iOS or SwiftUI application so on-device visual annotations are sent directly to Cursor or another MCP coding agent. Use when adding AnnotateKit, enabling iOS UI annotation, or setting up the AnnotateKit MCP workflow.
---

# Install AnnotateKit in an iOS app

Set up the complete iOS-to-agent annotation loop, not only the MCP client.

1. Confirm the repository contains an iOS 17+ Swift or SwiftUI application. Locate its app entry point and root content view.
2. Add `https://github.com/Connected-Mate/AnnotateKit` as a Swift Package dependency, using the latest stable release compatible with the project. Preserve the project's existing dependency-management approach. For an Xcode project, prefer its existing package references; do not rewrite the project file blindly.
3. Link the `AnnotateKit` product to the iOS application target.
4. Import `AnnotateKit` and attach `.annotationOverlay()` once, near the root of the app's SwiftUI hierarchy. Do not attach multiple overlays.
5. Configure the bridge endpoint when needed:

```swift
AnnotateKit.configure(endpoint: URL(string: "http://127.0.0.1:4747"))
```

Use `127.0.0.1` for Simulator. For a physical iPhone, use the development Mac's reachable LAN address. Never put the debug bridge in production configuration.
6. Ensure the bundled `annotatekit` MCP server is active. It starts the local iOS HTTP bridge on port `4747` and exposes the same in-memory annotation session to Cursor.
7. Build the iOS target without launching a simulator unless the repository instructions and user explicitly authorize it. Report any host-app Info.plist additions required by optional voice dictation.
8. Explain the finished loop to the developer: run the Debug app, annotate the exact on-screen element, add a note, and tap **Send**. Cursor can then call `annotatekit_list_sessions` and `annotatekit_get_pending`, implement the fix, reply, and resolve it.

AnnotateKit is debug tooling. Do not add release-only code paths, production telemetry, or public network exposure as part of installation.
