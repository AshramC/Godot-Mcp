---
name: godot-bridge
description: Use when operating Godot 4 projects through the Godot MCP FastMCP Gateway, including inspecting projects, controlling the Godot editor, editing scenes, nodes, resources, scripts, debugging, capturing editor viewport screenshots, running projects or tests, and diagnosing Godot output.
---

# Godot MCP

Use this skill when a task should operate a Godot project through the `godot-bridge` MCP server.

## Connection Model

- Connect agents to the FastMCP Gateway endpoint, normally `http://127.0.0.1:3001/mcp`.
- Do not connect agents directly to the Godot Bridge at `ws://127.0.0.1:3000/bridge`.
- The Godot plugin Bridge must be enabled in the target project for editor tools to appear.
- Gateway host-side tools can still work when the editor plugin is not running.
- Start the Gateway with `uv run godot-bridge-gateway --project <target-project>` from the godot-bridge repository root. The Gateway reads the project's `.bridge_token` internally.

## Client Configuration

- If asked to set up a client, read `.gateway_endpoint.json` first and use its `mcp_url` when present.
- If the endpoint file is absent, use `http://127.0.0.1:3001/mcp`.
- Configure only the FastMCP Gateway endpoint, never the Bridge URL.
- For CLI clients, use:
  - `claude mcp add --scope user --transport http godot-bridge <mcp_url>`
  - `codex mcp add --scope user --transport http godot-bridge <mcp_url>`
  - `gemini mcp add --scope user --transport http godot-bridge <mcp_url>`
- Use `--scope project` when the user wants project-local config.
- If configuration cannot be applied automatically, give the user the exact command or value to paste.

## Workflow

1. Call `project_environment` first to detect Godot and inspect the target project.
2. Call `godot_bridge_health` before using Bridge tools.
3. Make edits with `res://` resource paths whenever possible.
4. Save changed scenes/resources/scripts after modifications.
5. Verify with `project_test` for pass/fail workflows or `project_runtime` for exploratory runs.
6. Use `project_diagnostics` when runtime output contains errors, warnings, failed tests, or unclear behavior.

Bridge tools use a slim `godot_*` surface: `godot_scene`, `godot_node`, `godot_script`, `godot_resource`, `godot_project`, `godot_editor`, `godot_debug`, and `godot_view`. Old full-wrapper names are not exposed and do not have compatibility aliases.

## Safety

- Avoid destructive deletes unless the user explicitly requests them.
- Prefer small, targeted scene and project changes.
- Do not assume Bridge tools are available just because the Gateway is reachable.
- If `3001` is occupied, use the `mcp_url` from `.gateway_endpoint.json`.

## Useful Prompt

```text
Use $godot-bridge. First inspect project_environment and godot_bridge_health, then edit the Godot project, save changes, run project_test or project_runtime, and use project_diagnostics if anything fails.
```
