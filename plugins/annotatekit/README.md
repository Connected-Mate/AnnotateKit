# AnnotateKit for Cursor

AnnotateKit connects precise visual feedback from a running iOS Debug build directly to Cursor.

## Start in one command

After installing the plugin, open the iOS project in Cursor and run:

```text
/setup-annotatekit
```

Cursor adds the AnnotateKit Swift Package to the iOS app target, attaches the Debug overlay, configures the local bridge, and verifies the build. Plugin installation itself provisions the bundled MCP definition; project setup is an explicit command because adding a package changes the user's source repository.

Then start the live loop:

```text
/watch-annotatekit
```

## Daily loop

Run the app, tap the exact UI element, write a note, and tap **Send**. The waiting MCP call returns the annotation to the active Cursor chat, including position, accessibility identity, nearby text, hierarchy, intent, severity, and discussion thread. Cursor can then implement, verify, reply, acknowledge, resolve, or dismiss before continuing to watch.

MCP does not create a brand-new Cursor chat on its own. `/watch-annotatekit` activates the hands-free loop in the chat where the developer wants the work performed.

The local connector exposes the iOS bridge on port `4747`. Simulator uses `127.0.0.1`; a physical iPhone uses the development Mac's reachable LAN address.
