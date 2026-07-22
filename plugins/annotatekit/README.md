# AnnotateKit for Codex and Cursor

AnnotateKit connects precise visual feedback from a running iOS Debug build directly to the active Codex or Cursor conversation.

## Start in one command

After installing the plugin, open the iOS project in your coding agent and start the setup workflow.

In Codex, use the starter prompt:

```text
Set up AnnotateKit in this iOS app.
```

In Cursor, run:

```text
/setup-annotatekit
```

The agent adds the AnnotateKit Swift Package to the iOS app target, attaches the Debug overlay, configures the local bridge, and verifies the build. Plugin installation itself provisions the bundled MCP definition; project setup is an explicit workflow because adding a package changes the user's source repository.

Then start the live loop with “Watch for AnnotateKit feedback and implement each verified fix.” in Codex, or with this command in Cursor:

```text
/watch-annotatekit
```

## Daily loop

Run the app, tap the exact UI element, write a note, and tap **Send**. The waiting MCP call returns the annotation to the active conversation, including position, accessibility identity, nearby text, hierarchy, intent, severity, and discussion thread. The agent can then implement, verify, reply, acknowledge, resolve, or dismiss before continuing to watch.

MCP does not create a brand-new conversation on its own. The watch workflow activates the hands-free loop in the thread where the developer wants the work performed.

The local connector exposes the iOS bridge on port `4747`. Simulator uses `127.0.0.1`; a physical iPhone uses the development Mac's reachable LAN address.
