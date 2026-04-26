# Godot MCP Bridge

[![Python 3.10+](https://img.shields.io/badge/python-3.10+-blue.svg)](https://www.python.org/)
[![Godot 4.x](https://img.shields.io/badge/godot-4.x-478CBF.svg)](https://godotengine.org/)
[![FastMCP](https://img.shields.io/badge/MCP-FastMCP-orange.svg)](https://github.com/jlowin/fastmcp)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

English | **[中文](README.md)**

> Let AI assistants (Claude, Gemini, Codex, etc.) write code, edit scenes, and run your Godot 4 project directly inside the editor — via the MCP protocol for real-time, two-way communication.


---

## Why Godot MCP Bridge?

There are over a dozen Godot MCP solutions out there. Here's what makes this one different:

- **🏗️ Two-Layer Architecture (Gateway + Bridge)** — The AI client connects to a Python Gateway, which forwards requests to the editor plugin. This means project detection, headless execution, and diagnostics work **without the Godot editor running** — great for CI/CD and automation pipelines.
- **🧪 Built-in Test & Diagnostics Loop** — `project_test` runs headless with success/failure pattern matching and JSON output extraction; `project_diagnostics` parses Godot output into structured errors with file paths and line numbers. The AI can complete the full "edit → run → diagnose → fix" cycle.
- **📦 Slim Tool Design** — 8 tool groups covering 60+ actions via an `action` parameter, instead of exposing hundreds of individual tools. This saves significant LLM context window space and makes capabilities easier for the AI to reason about.
- **🐍 Python Native** — Built on FastMCP + uv. One command to start, no Node.js build step required. Zero friction for Python developers.
- **🌐 Multi-Client Friendly** — HTTP MCP endpoint natively supports multiple clients. No stdio one-to-one binding. Claude Code, Gemini CLI, and Codex all work plug-and-play.

---

## Prerequisites

- [Godot 4.x](https://godotengine.org/)
- [uv](https://docs.astral.sh/uv/getting-started/installation/) (Python package manager)
- An MCP-capable AI client: Claude Code, Gemini CLI, Codex, or similar

---

## Quick Start

### Step 1: Install the Godot Plugin

Copy `addons/godot_bridge/` from this repository into your Godot project:

```
your-godot-project/
└── addons/
    └── godot_bridge/   ← copy here
```

Enable the plugin in Godot: `Project → Project Settings → Plugins → Godot Bridge → Enable`

Open the **Godot AI Connector** panel on the right dock, switch to **Connection**, and click **Start Service**.

### Step 2: Start the Gateway

Run this from the **root of this repository** (`gateway/`, `pyproject.toml`, and `uv.lock` stay here — do not copy them to your Godot project):

```bash
uv run godot-bridge-gateway --project /path/to/your-godot-project
```

> The Godot panel's **Client Setup** tab generates the full command with the correct project path; prefer copying that command. The Gateway reads the project's `.bridge_token` internally, so you do not need to pass token files manually.  
> If port 3001 is already in use, append `--auto-port`. The actual MCP URL will be written to that Godot project's `.gateway_endpoint.json`.

### Step 3: Connect Your AI Client

In the Godot panel, open the **Client Setup** tab and copy the **Initial Instruction for AI**. For manual setup, copy the **AI client connection address** into any MCP-capable client.

---

## AI Agent Integration

This project ships with ready-made behavioral guides so AI agents work correctly out of the box — no extra prompt engineering required:

- **[`AGENTS.md`](AGENTS.md)** — Agent behavioral specification. Defines the standard workflow (detect environment → health check → edit → save → test → diagnose), safety rules (prefer `res://` paths, avoid destructive deletes), and client configuration methods. Automatically consumed by Claude Code, Codex, and similar tools.
- **[`skills/godot-mcp/SKILL.md`](skills/godot-mcp/SKILL.md)** — Claude Code skill pack. Place the `skills/` directory in your project and Claude Code will auto-load the skill, enabling the agent to call tools in the correct order without manual prompting.

---

## Architecture

```
AI Client (Claude Code / Gemini CLI / Codex)
   │  MCP (HTTP)
   ▼
FastMCP Gateway  (this repo, http://127.0.0.1:3001/mcp)
   │  WebSocket           ← Host-side tools operate at this layer independently
   ▼
Godot Bridge Plugin  (target project, ws://127.0.0.1:3000/bridge)
   │
   ▼
Godot 4 Editor           ← Bridge tools operate at this layer
```

- AI clients connect **only to the Gateway** — never directly to the Bridge.
- The Gateway handles protocol translation and exposes host-side tools (no editor required).
- The Bridge plugin handles live editor operations.

---

## Tools

### Gateway Host Tools (available without the Godot editor)

| Tool | Purpose | Example |
|---|---|---|
| `project_environment` | Detect Godot version, find projects | "Find all Godot projects in this directory" |
| `project_runtime` | Launch the editor, run projects/scenes, read output | "Run the main scene and show me the console output" |
| `project_diagnostics` | Parse Godot output into structured errors and warnings | "Analyze the run log and tell me which scripts have errors" |
| `project_test` | Run headless and return pass/fail | "Run this scene and check if it outputs test_passed" |
| `godot_bridge_health` | Check whether the editor Bridge is online | Pre-flight check before any editor operation |

### Bridge Tools (require the Godot editor + plugin running)

| Tool | Main Actions | Example |
|---|---|---|
| `godot_scene` | Open, save, create, play/stop scenes | "Create a new scene with Node3D root, save to res://levels/" |
| `godot_node` | Find, create, delete, edit properties, transform | "Add a CollisionShape3D under the Player node, set its position" |
| `godot_script` | Create, read, write, attach scripts; open in editor | "Create a new script for the Player node with movement logic" |
| `godot_resource` | Query, create, copy, move, UID management | "List all texture resources under res://assets/" |
| `godot_project` | Project settings, input actions, autoloads | "Add a move_left input action bound to the A key" |
| `godot_editor` | Editor status, filesystem refresh, Inspector, ClassDB | "Show me all properties and methods of CharacterBody3D" |
| `godot_debug` | Debugger sessions, breakpoints, capture debug messages | "Set a breakpoint at line 42 of player.gd" |
| `godot_view` | Capture editor 2D/3D viewport screenshots | "Take a screenshot of the 3D viewport so I can see the layout" |

---

## FAQ

<details>
<summary><b>Gateway starts fine, but my AI only sees host tools — no godot_scene etc.?</b></summary>

Make sure the Godot plugin is enabled and you clicked **Start Service** in the panel. The status indicator should show **Running**.
</details>

<details>
<summary><b>Port conflict?</b></summary>

Start the Gateway with `--auto-port`, then copy the actual AI client connection address from the **Connection** tab and reconfigure your client.
</details>

<details>
<summary><b>Which AI clients are supported?</b></summary>

Any MCP-capable client works, including Claude Code, Gemini CLI, OpenAI Codex, Cursor, and more. The Gateway exposes a standard HTTP MCP endpoint — no stdio transport dependency.
</details>

<details>
<summary><b>How is this better than having AI read/write .tscn/.gd files directly?</b></summary>

Bridge tools operate through the Godot editor API, which correctly handles UIDs, resource references, and scene tree hierarchies. This avoids the compatibility pitfalls of manually editing text-based formats. You also get to see changes reflected in the editor in real time.
</details>

<details>
<summary><b>Can I use just the Gateway without the editor plugin?</b></summary>

Yes. The host-side tools (`project_environment`, `project_runtime`, `project_test`, `project_diagnostics`) do not require the editor. You can use them to detect projects, run headless, and analyze errors. Only the `godot_*` editor tools become unavailable.
</details>

<details>
<summary><b>Plugin translations not updating after reload?</b></summary>

Fully disable then re-enable the plugin in Godot (just reloading scripts is not enough).
</details>

---

## License

This project is licensed under the [MIT License](LICENSE).

---

<details>
<summary>Developers: smoke tests</summary>

```bash
# Host-side tools only
uv run python -m gateway.smoke_test \
  --expect-tool project_environment \
  --expect-tool project_runtime \
  --expect-tool project_diagnostics \
  --expect-tool project_test \
  --expect-tool godot_bridge_health

# Bridge tools (requires Godot plugin running)
uv run python -m gateway.smoke_test \
  --expect-tool godot_scene \
  --expect-tool godot_node \
  --expect-tool godot_script \
  --expect-tool godot_resource \
  --expect-tool godot_project \
  --expect-tool godot_editor \
  --expect-tool godot_debug \
  --expect-tool godot_view
```

</details>
