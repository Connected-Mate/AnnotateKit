---
name: setup-annotatekit
description: Install AnnotateKit in the current iOS app and verify the complete app-to-Cursor annotation loop.
---

Set up AnnotateKit end to end in the current iOS project.

Follow the `install-annotatekit-ios` skill. Add the Swift Package to the application target, attach one `.annotationOverlay()` at the SwiftUI root, configure the Debug bridge for this development environment, and verify that the bundled `annotatekit` MCP server is available.

Do not stop after editing package metadata. Build the generic iOS target, explain how to run the Debug app, and finish with this exact user journey:

1. Open the AnnotateKit toolbar in the running iOS app.
2. Tap the exact UI element to annotate.
3. Enter the feedback and tap **Send**.
4. In Cursor, ask to process pending AnnotateKit feedback.

Report any step that could not be verified instead of claiming setup is complete.
