#!/usr/bin/env node
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { createHttpServer } from "./http.js";
import { createMcpServer } from "./mcp.js";
import { Store } from "./store.js";

const store = new Store(); const mode = process.argv[2] ?? "stdio";
if (mode === "http" || mode === "server") { const port = Number(process.env.PORT ?? 4747); createHttpServer(store).listen(port, "0.0.0.0", () => console.error(`AnnotateKit MCP listening on http://0.0.0.0:${port}`)); }
else {
  const port = Number(process.env.ANNOTATEKIT_PORT ?? 4747);
  createHttpServer(store).listen(port, "0.0.0.0", () => console.error(`AnnotateKit iOS bridge listening on http://0.0.0.0:${port}`));
  await createMcpServer(store).connect(new StdioServerTransport());
}
