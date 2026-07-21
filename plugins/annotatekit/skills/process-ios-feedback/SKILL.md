---
name: process-ios-feedback
description: Read and implement pending AnnotateKit iOS or SwiftUI visual feedback delivered by the AnnotateKit MCP connector, then resolve each accepted annotation.
---

# Process AnnotateKit feedback

1. Call `annotatekit_list_sessions`, select the relevant active session, then call `annotatekit_get_pending`.
2. For each annotation, use its accessibility identifier, element path, nearby text, view chain, and screen hint to locate the corresponding Swift or UIKit source. Do not assume captured user-visible text is a source literal; check string catalogs and localized resources.
3. Acknowledge the annotation when work begins. Implement only the requested change and verify it with the repository's normal checks.
4. Ask for clarification by calling `annotatekit_reply` when identity or intent is ambiguous.
5. Resolve only after the change is implemented and verified. Dismiss only when the user explicitly requests dismissal.
