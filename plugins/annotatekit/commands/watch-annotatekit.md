---
name: watch-annotatekit
description: Wait for iOS feedback sent from AnnotateKit, implement it, verify it, and continue watching.
---

Start the hands-free AnnotateKit feedback loop for this iOS project.

1. Call `annotatekit_list_sessions`. If there is one active session, use it; otherwise ask the developer which running iOS app to watch.
2. Call `annotatekit_watch_send` for that session with a 120-second timeout.
3. When `sent` is true, process every returned pending annotation using the `process-ios-feedback` skill: acknowledge, locate the exact source, implement, build or test, and resolve only verified work.
4. Summarize completed changes, then call `annotatekit_watch_send` again while the developer wants the loop to continue.
5. A timeout is not an error. State that no new Send was received and offer to keep watching.

Never claim that MCP can create a new Cursor chat by itself. This command must run in an active chat; once active, tapping **Send** in the iOS overlay releases the waiting tool call and lets Cursor continue automatically.
