# Godot MCP Agent Guide

Use this guide when an agent works with Godot projects through Godot MCP.

## Architecture

- The Godot editor plugin Bridge runs inside the target Godot project.
- The Bridge listens locally at `ws://127.0.0.1:3000/bridge`.
- The Python FastMCP Gateway runs from this repository root.
- Agents must connect to the Gateway MCP endpoint, not directly to the Bridge.
- The default MCP endpoint is `http://127.0.0.1:3001/mcp`.

## Placement

- Copy only `addons/godot_bridge/` into the target Godot project as `addons/godot_bridge/`.
- Keep `gateway/`, `pyproject.toml`, and `uv.lock` in this repository.
- Start the Gateway from this repository root with the command shown in the Godot plugin's Client Setup tab. It uses `--project <target-project>`; the Gateway reads `<target-project>/.bridge_token` internally and writes `<target-project>/.gateway_endpoint.json`.
- If `3001` is occupied, start with the generated command that includes `--auto-port` and use the `mcp_url` from `.gateway_endpoint.json`.

## Client Configuration

- Prefer configuring the user's AI client from the agent side when shell and filesystem access are available.
- Read `.gateway_endpoint.json` first if it exists; use its `mcp_url` as the MCP endpoint.
- If the endpoint file does not exist, use `http://127.0.0.1:3001/mcp`.
- Configure clients to connect only to the Gateway endpoint. Never configure clients to connect to the Bridge URL.
- For CLI clients, prefer these commands:
  - `claude mcp add --scope user --transport http godot-bridge <mcp_url>`
  - `codex mcp add --scope user --transport http godot-bridge <mcp_url>`
  - `gemini mcp add --scope user --transport http godot-bridge <mcp_url>`
- Use `--scope project` instead of `--scope user` when the user wants project-local configuration.
- If direct client configuration is not possible, tell the user the exact command or config value to apply.

## Standard Workflow

1. Inspect the environment with `project_environment`.
2. Check editor connectivity with `godot_bridge_health`.
3. Use the slim Bridge tools only after the health check succeeds: `godot_scene`, `godot_node`, `godot_script`, `godot_resource`, `godot_project`, `godot_editor`, `godot_debug`, `godot_view`.
4. Save changed scenes, resources, scripts, and project files after edits.
5. Verify with `project_test` or `project_runtime`.
6. If execution fails, analyze output with `project_diagnostics`.

## Safety Rules

- Prefer `res://` paths for Godot resources.
- Do not delete nodes, resources, scenes, or scripts unless the user explicitly asks.
- Avoid broad rewrites of scenes, project settings, and imported resources.
- Treat Gateway host-side tools as available without the Bridge; treat all `godot_*` editor tools as Bridge-dependent.
