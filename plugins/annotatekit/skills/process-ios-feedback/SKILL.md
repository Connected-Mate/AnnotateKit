---
name: process-ios-feedback
description: Read and implement pending AnnotateKit iOS or SwiftUI visual feedback delivered by the AnnotateKit MCP connector, then resolve each accepted annotation.
---

# Process AnnotateKit feedback

1. Call `annotatekit_list_sessions` and select the relevant active session. If the user asks to watch, wait with `annotatekit_watch_send` for up to 120 seconds; otherwise call `annotatekit_get_pending` immediately.
2. For each annotation, use its accessibility identifier, element path, nearby text, view chain, and screen hint to locate the corresponding Swift or UIKit source. Do not assume captured user-visible text is a source literal; check string catalogs and localized resources.
3. Acknowledge the annotation when work begins. Implement only the requested change and verify it with the repository's normal checks.
4. Ask for clarification by calling `annotatekit_reply` when identity or intent is ambiguous.
5. Resolve only after the change is implemented and verified. Dismiss only when the user explicitly requests dismissal.
6. In watch mode, summarize the completed batch and call `annotatekit_watch_send` again while the user wants the active thread to keep listening. A timeout is not an error.

The bundled MCP bridge can resume a waiting tool call in the current Codex thread, but it cannot create a brand-new thread by itself. Never claim otherwise.
