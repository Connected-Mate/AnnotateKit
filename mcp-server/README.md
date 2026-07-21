# AnnotateKit MCP

The official connector between AnnotateKit's iOS overlay and MCP clients.

```bash
npx -y @connected-mate/annotatekit-mcp          # stdio MCP + iOS bridge on :4747
npx -y @connected-mate/annotatekit-mcp http     # HTTP + MCP on :4747
```

Set the Swift package endpoint to `http://127.0.0.1:4747` in Simulator or to the Mac's LAN address on a physical device. MCP clients use `/mcp`; the iOS app uses the session endpoints on the same origin.

Environment: `PORT` selects the HTTP port (default `4747`). The connector stores sessions in memory and is intended for debug feedback, not permanent storage.
