# AnnotateKit for Cursor

AnnotateKit connects precise visual feedback from a running iOS Debug build directly to Cursor.

## Start in one command

After installing the plugin, open the iOS project in Cursor and run:

```text
/setup-annotatekit
```

Cursor adds the AnnotateKit Swift Package to the iOS app target, attaches the Debug overlay, configures the local bridge, and verifies the build. Plugin installation itself provisions the bundled MCP definition; project setup is an explicit command because adding a package changes the user's source repository.

## Daily loop

Run the app, tap the exact UI element, write a note, and tap **Send**. Cursor receives the annotation through the bundled MCP server, including position, accessibility identity, nearby text, hierarchy, intent, severity, and discussion thread. Cursor can then implement, reply, acknowledge, resolve, or dismiss.

The local connector exposes the iOS bridge on port `4747`. Simulator uses `127.0.0.1`; a physical iPhone uses the development Mac's reachable LAN address.
