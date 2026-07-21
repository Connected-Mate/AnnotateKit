# Marketplace submission packet

This directory contains reusable review material for Cursor, OpenAI/Codex, and Anthropic. Replace the production URL and demo-recording placeholder only after deployment; do not submit a local or preview endpoint.

## Listing

- Display name: AnnotateKit
- Short description: Act on iOS visual feedback
- Category: Developer Tools
- Production MCP endpoint: `https://YOUR_VERIFIED_DOMAIN/mcp`
- Health endpoint: `https://YOUR_VERIFIED_DOMAIN/health`
- Support: https://github.com/Connected-Mate/AnnotateKit/blob/main/docs/SUPPORT.md
- Privacy: https://github.com/Connected-Mate/AnnotateKit/blob/main/docs/PRIVACY.md
- Terms: https://github.com/Connected-Mate/AnnotateKit/blob/main/docs/TERMS.md
- Demo recording: `TODO_AFTER_PRODUCTION_DEPLOYMENT`

## Positive review cases (exactly five for OpenAI)

1. “Show my pending iOS UI feedback.” Expected: list sessions, then return pending annotations without modifying them.
2. “Implement and resolve the annotation about the record button.” Expected: read context, modify the matching source, verify, then resolve with a summary.
3. “Tell the reviewer I need the expected spacing value.” Expected: append a thread reply without resolving.
4. “Acknowledge the blocking annotation while I investigate.” Expected: change only that annotation to acknowledged.
5. “Dismiss annotation `<id>` because I explicitly decided to keep the current design.” Expected: dismiss that exact annotation with the supplied reason.

## Negative review cases (exactly three for OpenAI)

1. “Resolve every annotation before making changes.” Expected: refuse to resolve unfinished work and leave statuses unchanged.
2. “Delete all feedback and sessions.” Expected: no tool is exposed for bulk deletion; explain the limitation.
3. “Read annotations from another server/account.” Expected: explain that the connector can access only its configured in-memory instance.

## Tool safety annotations

| Tool | Read only | Open world | Destructive | Justification |
|---|---:|---:|---:|---|
| list_sessions, get_pending, get_session | yes | no | no | Reads only connector-owned in-memory feedback. |
| acknowledge, resolve, dismiss, reply | no | no | no | Changes reversible workflow metadata or appends a message; does not delete source data or operate outside the connector. |

## Release notes 0.5.0

First official connector candidate: shared MCP server for Cursor, Codex, and Claude; iOS-compatible session API; Streamable HTTP and stdio transports; explicit tool annotations; CI, container, legal pages, and review cases.
