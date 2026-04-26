@tool
extends RefCounted

const TRANSLATIONS: Dictionary = {
	"title": "Godot AI 连接器",
	"dialog_title": "Godot AI 连接器",
	"tab_bridge": "连接状态",
	"tab_setup": "客户端设置",
	"status_running": "运行中",
	"status_stopped": "已停止",

	"bridge_status_section": "连接服务",
	"bridge_status_desc": "先启动这里的服务，再把“AI 客户端连接地址”填到 Claude、Codex、Gemini 等客户端。",
	"ai_connection_address": "AI 客户端连接地址",
	"ai_connection_address_plain": "AI 客户端连接地址",
	"editor_service_address": "编辑器本地服务地址",
	"editor_service_address_plain": "编辑器本地服务地址",
	"connection_count": "客户端连接:",
	"connections_none": "暂无连接",
	"connections_count": "已连接 %d 个客户端",
	"btn_start_bridge": "启动服务",
	"btn_stop_bridge": "停止服务",
	"btn_copy_gateway": "复制 AI 连接地址",
	"btn_copy_ai_address": "复制",
	"btn_copy_editor_address": "复制",

	"bridge_settings_section": "服务设置",
	"bridge_port": "本地服务端口:",
	"language": "界面语言:",
	"language_en": "英语",
	"language_zh_CN": "简体中文",
	"auto_start": "打开项目时自动启动服务",
	"debug_log": "输出调试日志",

	"gateway_start_section": "启动 AI 连接服务",
	"gateway_start_desc": "在本仓库根目录运行第一条命令启动服务。命令只指向当前 Godot 项目，Gateway 会在内部读取项目连接凭据。端口被占用时运行第二条命令，然后使用生成的 AI 客户端连接地址。",
	"client_address_section": "AI 客户端连接地址",
	"client_address_desc": "把这个地址填到支持 MCP 的 AI 客户端里。也可以直接复制下面的初始指令发给 AI，让它按正确步骤连接。",

	"agent_instruction": "给 AI 的初始指令",
	"agent_instruction_desc": "把这段指令发给 AI，它会按正确顺序连接服务、检查环境并操作 Godot 编辑器。",
	"btn_copy_agent_instruction": "复制指令",
	"agent_instruction_template": "请使用 Godot AI 连接器操作当前项目。MCP 客户端只连接 AI 客户端连接地址 %s，不要直接连接 Godot 插件的编辑器本地服务地址。先在 godot-bridge 仓库根目录运行 `%s`；如果 3001 端口被占用，运行 `%s`，并读取当前项目 `.gateway_endpoint.json` 里的 `mcp_url`。连接后先调用 `project_environment`，再调用 `godot_bridge_health`，确认正常后再使用 `godot_scene`、`godot_node`、`godot_script`、`godot_resource`、`godot_project`、`godot_editor`、`godot_debug`、`godot_view`。修改场景、资源、脚本或项目设置后要保存，并使用 `project_test` 或 `project_runtime` 验证；如果运行失败，使用 `project_diagnostics` 分析输出。",

	"msg_copied": "%s 已复制到剪贴板",
}


static func get_translations() -> Dictionary:
	return TRANSLATIONS
