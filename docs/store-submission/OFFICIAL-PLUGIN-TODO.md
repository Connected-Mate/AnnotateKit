# AnnotateKit official plugin release checklist

Last reviewed: 2026-07-22

Legend: `[x]` complete, `[ ]` pending, `BLOCKED` requires an external account, identity, domain, or legal action.

## Shared production foundation — P0

- [x] Ship the iOS Swift Package and Debug-only annotation overlay.
- [x] Ship MCP over stdio and Streamable HTTP.
- [x] Expose narrowly scoped list, read, acknowledge, reply, resolve, and dismiss tools.
- [x] Add explicit MCP safety annotations.
- [x] Add Docker packaging, health checks, CI, privacy policy, terms, and support pages.
- [x] Reuse the original AnnotateKit application icon.
- [ ] Replace the global in-memory hosted store with tenant-isolated workspaces.
- [ ] Add production authentication or secure capability-based pairing between the iOS app and agent.
- [ ] Ensure one customer cannot enumerate or modify another customer's sessions or annotations.
- [ ] Add persistence, retention limits, deletion controls, rate limiting, payload limits, and log redaction.
- [ ] Add an OpenAI domain-verification endpoint that returns exactly the active challenge token.
- [ ] Deploy `https://<verified-domain>/mcp` and `https://<verified-domain>/health`.
- [ ] Run a production security review and cross-tenant isolation tests.
- [ ] Record the complete iOS annotation → Send → agent fix → resolve demonstration.

## Official Codex / OpenAI plugin — P0

### Bundle and UX

- [x] Create `.codex-plugin/plugin.json` with production listing metadata.
- [x] Bundle the MCP server locally for development installs.
- [x] Add the `install-annotatekit-ios` and `process-ios-feedback` skills.
- [x] Add setup, pending-feedback, and live-watch starter prompts.
- [x] Validate the plugin with the Codex plugin validator.
- [x] Install and test `annotatekit@personal` in Codex.
- [x] Verify the installed copy starts MCP and exposes its tools.
- [ ] Point the public app portion at the production HTTPS MCP endpoint.
- [ ] Build the final app-plus-skills upload bundle from the exact reviewed tree.
- [ ] Verify installation and workflows in a clean Codex profile and a clean iOS sample project.

### Submission packet

- [x] Prepare the listing name, descriptions, category, logo, website, support, privacy, and terms URLs.
- [x] Draft exactly five positive and three negative review cases.
- [x] Draft initial release notes and tool-safety justifications.
- [ ] Expand every review case with fixture data, expected tool sequence, and expected result shape.
- [ ] Add the production MCP URL, authentication instructions, CSP domains, and reviewer credentials if required.
- [ ] Confirm tool responses contain no secrets, unnecessary personal data, or internal debug identifiers.
- [ ] Select supported countries based on legal and support readiness.

### OpenAI Platform actions

- [ ] `BLOCKED` Confirm the publishing organization has **Apps Management: Write**.
- [ ] `BLOCKED` Complete individual or business identity verification for the AnnotateKit publisher.
- [ ] Create an **App + Skills / With MCP** draft at https://platform.openai.com/plugins.
- [ ] Enter the listing and upload the final skill bundle.
- [ ] Enter the production MCP URL and select **Scan Tools**.
- [ ] Complete domain verification at `/.well-known/openai-apps-challenge`.
- [ ] Resolve every portal scan, metadata, policy, and security warning.
- [ ] Enter the five positive and three negative tests.
- [ ] Review availability, release notes, privacy disclosures, and policy attestations.
- [ ] `BLOCKED` Obtain explicit publisher approval before accepting attestations and selecting **Submit for Review**.
- [ ] Track review feedback and submit corrected builds until approved.
- [ ] `BLOCKED` After approval, obtain explicit approval and select **Publish**.
- [ ] Verify AnnotateKit appears and installs from the public Plugins Directory in both Codex and ChatGPT.

## Claude Code plugin — P0

### Plugin package

- [ ] Create `plugins/annotatekit/.claude-plugin/plugin.json` using the Claude Code plugin schema.
- [ ] Declare the bundled MCP server using `${CLAUDE_PLUGIN_ROOT}` so cached installs remain self-contained.
- [ ] Reuse the two reviewed skills and add Claude-specific setup/watch commands only where useful.
- [ ] Ensure no file in the installed plugin references a path outside the plugin directory.
- [ ] Update every description that still says only “Cursor” or “Codex” to describe Claude Code accurately.
- [ ] Validate with `claude plugin validate .`.
- [ ] Test with `claude --plugin-dir ./plugins/annotatekit`.
- [ ] Verify setup in a clean iOS sample project without launching a simulator unless explicitly authorized.
- [ ] Verify Send wakes the active Claude Code workflow and resolve/reply changes return to the iOS app.

### Independent marketplace distribution

- [ ] Create `.claude-plugin/marketplace.json` at the repository root.
- [ ] Add `annotatekit` with source `./plugins/annotatekit`, version, description, category, and tags.
- [ ] Validate the complete marketplace with `claude plugin validate .`.
- [ ] Add it locally with `claude plugin marketplace add .`.
- [ ] Install with `claude plugin install annotatekit@annotatekit` and run `/reload-plugins`.
- [ ] Test update behavior after increasing the plugin version.
- [ ] Publish installation instructions using `Connected-Mate/AnnotateKit` as the GitHub marketplace source.

### Official Anthropic marketplace

- [ ] Finalize the production listing, screenshots/demo, support, privacy, terms, and security explanation.
- [ ] Decide whether the official listing uses the local bundled MCP, the hosted HTTPS MCP, or both; document the privacy trade-off.
- [ ] Confirm the plugin works from Claude Code's versioned cache, not only from the repository checkout.
- [ ] Submit through https://claude.ai/settings/plugins/submit or https://platform.claude.com/plugins/submit.
- [ ] `BLOCKED` Obtain explicit publisher approval before accepting submission terms or attestations.
- [ ] Respond to Anthropic review feedback and publish the approved release.
- [ ] Verify installation from `claude-plugins-official` and the public listing at https://claude.com/plugins.

## Launch order

1. Secure and deploy the shared multi-tenant MCP service.
2. Complete the OpenAI App + Skills submission and the Anthropic plugin package in parallel.
3. Publish the independent Claude marketplace immediately after clean-profile validation.
4. Submit to OpenAI and Anthropic review portals.
5. Publish only after approval, then run post-install smoke tests from both official directories.

## Definition of done

AnnotateKit is complete only when a new user can install it from the official directory, add the Swift Package to an iOS project through the agent workflow, annotate an exact UI element, tap **Send**, receive the annotation in the active coding conversation, implement and verify the change, and see the reply or resolution return to the app without accessing another user's data.
