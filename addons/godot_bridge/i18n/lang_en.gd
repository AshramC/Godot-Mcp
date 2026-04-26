@tool
extends RefCounted

const TRANSLATIONS: Dictionary = {
	"title": "Godot AI Connector",
	"dialog_title": "Godot AI Connector",
	"tab_bridge": "Connection",
	"tab_setup": "Client Setup",
	"status_running": "Running",
	"status_stopped": "Stopped",

	"bridge_status_section": "Connection Service",
	"bridge_status_desc": "Start this service first, then use the AI client connection address in Claude, Codex, Gemini, or another MCP client.",
	"ai_connection_address": "AI client connection address",
	"ai_connection_address_plain": "AI client connection address",
	"editor_service_address": "Editor local service address",
	"editor_service_address_plain": "Editor local service address",
	"connection_count": "Client connections:",
	"connections_none": "No clients connected",
	"connections_count": "%d client(s) connected",
	"btn_start_bridge": "Start Service",
	"btn_stop_bridge": "Stop Service",
	"btn_copy_gateway": "Copy AI Address",
	"btn_copy_ai_address": "Copy",
	"btn_copy_editor_address": "Copy",

	"bridge_settings_section": "Service Settings",
	"bridge_port": "Local service port:",
	"language": "Language:",
	"language_en": "English",
	"language_zh_CN": "Simplified Chinese",
	"auto_start": "Start the service when this project opens",
	"debug_log": "Print debug logs",

	"gateway_start_section": "Start AI Connection Service",
	"gateway_start_desc": "Run the first command from this repository root. It points at this Godot project, and the Gateway reads the project connection credentials internally. If the port is busy, run the second command and use the generated AI client connection address.",
	"client_address_section": "AI Client Connection Address",
	"client_address_desc": "Paste this address into an MCP-capable AI client. You can also copy the initial instruction below and send it to your AI.",

	"agent_instruction": "Initial Instruction for AI",
	"agent_instruction_desc": "Send this to your AI so it connects to the service, checks the environment, and then works inside Godot.",
	"btn_copy_agent_instruction": "Copy Instruction",
	"agent_instruction_template": "Use Godot AI Connector for this project. Configure the MCP client to connect only to the AI client connection address %s. Do not connect directly to the Godot plugin's editor local service address. Start the connection service from the godot-bridge repository with `%s`; if port 3001 is occupied, use `%s` and read `mcp_url` from this project's `.gateway_endpoint.json`. After connecting, call `project_environment` first, then `godot_bridge_health`, and only then use `godot_scene`, `godot_node`, `godot_script`, `godot_resource`, `godot_project`, `godot_editor`, `godot_debug`, and `godot_view`. Save changed scenes, resources, scripts, and project files, then verify with `project_test` or `project_runtime`; if execution fails, use `project_diagnostics`.",

	"msg_copied": "%s copied to clipboard",
}


static func get_translations() -> Dictionary:
	return TRANSLATIONS
