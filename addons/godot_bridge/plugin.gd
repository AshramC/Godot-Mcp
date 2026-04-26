@tool
extends EditorPlugin

const GodotBridgeServerScript = preload("http_bridge.gd")
const MCPLocalization = preload("i18n/localization.gd")


class MCPDebuggerHelper:
	extends EditorDebuggerPlugin

	signal runtime_event(event_name: String, payload: Dictionary)

	var captured_messages: Array[Dictionary] = []

	func _has_capture(capture: String) -> bool:
		return capture == "godot_bridge"

	func _capture(message: String, data: Array, session_id: int) -> bool:
		var entry := {
			"session_id": session_id,
			"message": message,
			"data": data,
			"time": Time.get_unix_time_from_system(),
		}
		captured_messages.append(entry)
		if message == "godot_bridge:ready":
			runtime_event.emit("runtime.ready", {"session_id": session_id, "data": data})
		elif message == "godot_bridge:response":
			runtime_event.emit("runtime.response", {"session_id": session_id, "data": data})
		return true

	func get_session_info() -> Array[Dictionary]:
		var result: Array[Dictionary] = []
		for index in range(get_sessions().size()):
			var session = get_session(index)
			if session:
				result.append({
					"id": index,
					"active": session.is_active(),
					"breaked": session.is_breaked(),
					"debuggable": session.is_debuggable(),
				})
		return result

	func set_breakpoint(session_id: int, path: String, line: int, enabled: bool) -> Dictionary:
		var session = get_session(session_id)
		if not session:
			return {"session_id": session_id, "updated": false, "error": "Session not found"}
		session.set_breakpoint(path, line, enabled)
		return {"session_id": session_id, "path": path, "line": line, "enabled": enabled, "updated": true}

	func send_debug_message(session_id: int, message: String, data: Array) -> Dictionary:
		var session = get_session(session_id)
		if not session:
			return {"session_id": session_id, "sent": false, "error": "Session not found"}
		var outbound = message if message.contains(":") else "godot_bridge:%s" % message
		session.send_message(outbound, data)
		return {"session_id": session_id, "message": outbound, "sent": true}

	func get_captured_messages(limit: int = 100) -> Array[Dictionary]:
		if limit <= 0 or captured_messages.size() <= limit:
			return captured_messages.duplicate()
		return captured_messages.slice(captured_messages.size() - limit)

	func clear_captured_messages() -> void:
		captured_messages.clear()


var bridge_server
var dock: Control
var _i18n
var _debugger_helper: MCPDebuggerHelper

var settings := {
	"port": 3000,
	"gateway_port": 3001,
	"host": "127.0.0.1",
	"auto_start": true,
	"debug_mode": false,
	"bridge_token": "",
	"language": "",
}

const SETTINGS_PATH = "user://godot_bridge_settings.json"
const BRIDGE_TOKEN_PATH = "res://.bridge_token"
const GATEWAY_ENDPOINT_PATH = "res://.gateway_endpoint.json"

var _tab_container: TabContainer
var _status_label: Label
var _status_indicator: ColorRect
var _bridge_url_label: LineEdit
var _gateway_url_label: LineEdit
var _connection_label: Label
var _port_spin: SpinBox
var _auto_start_check: CheckBox
var _debug_check: CheckBox
var _language_option: OptionButton

func _tr(key: String) -> String:
	if _i18n:
		return _i18n.get_text(key)
	return key


func _enter_tree() -> void:
	_load_settings()
	_ensure_bridge_token()

	MCPLocalization.reset_instance()
	_i18n = MCPLocalization.get_instance()
	if not str(settings.language).is_empty():
		_i18n.set_language(settings.language)

	bridge_server = GodotBridgeServerScript.new()
	bridge_server.name = "GodotBridgeServer"
	add_child(bridge_server)

	_debugger_helper = MCPDebuggerHelper.new()
	add_debugger_plugin(_debugger_helper)

	bridge_server.initialize(settings.port, settings.host, settings.debug_mode, settings.bridge_token)
	bridge_server.set_debugger_helper(_debugger_helper)

	_create_dock()

	if settings.auto_start:
		bridge_server.start()
		_update_status_ui()

	bridge_server.server_started.connect(_on_server_started)
	bridge_server.server_stopped.connect(_on_server_stopped)
	bridge_server.client_connected.connect(_update_connection_count)
	bridge_server.client_disconnected.connect(_update_connection_count)

	print("[Godot Bridge] Plugin loaded")


func _exit_tree() -> void:
	if bridge_server:
		bridge_server.stop()
		bridge_server.queue_free()

	if _debugger_helper:
		remove_debugger_plugin(_debugger_helper)
		_debugger_helper = null

	if dock:
		remove_control_from_docks(dock)
		dock.queue_free()

	print("[Godot Bridge] Plugin unloaded")


func _get_editor_scale() -> float:
	var editor = get_editor_interface()
	return editor.get_editor_scale() if editor else 1.0


func _scaled(value: float) -> float:
	return value * _get_editor_scale()


func _scaled_vec(value: Vector2) -> Vector2:
	return value * _get_editor_scale()


func _create_dock() -> void:
	dock = _create_dock_ui()
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, dock)


func _create_dock_ui() -> Control:
	var panel := VBoxContainer.new()
	panel.name = "GodotBridge"
	panel.custom_minimum_size = _scaled_vec(Vector2(300, 420))

	panel.add_child(_create_header())

	_tab_container = TabContainer.new()
	_tab_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tab_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(_tab_container)

	var bridge_tab := _create_bridge_tab()
	bridge_tab.name = _tr("tab_bridge")
	_tab_container.add_child(bridge_tab)

	var setup_tab := _create_setup_tab()
	setup_tab.name = _tr("tab_setup")
	_tab_container.add_child(setup_tab)

	return panel


func _create_header() -> Control:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", int(_scaled(12)))
	margin.add_theme_constant_override("margin_right", int(_scaled(12)))
	margin.add_theme_constant_override("margin_top", int(_scaled(8)))
	margin.add_theme_constant_override("margin_bottom", int(_scaled(8)))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", int(_scaled(10)))
	margin.add_child(row)

	_status_indicator = ColorRect.new()
	_status_indicator.custom_minimum_size = _scaled_vec(Vector2(12, 12))
	row.add_child(_centered(_status_indicator))

	var title := Label.new()
	title.text = _tr("title")
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(title)

	_status_label = Label.new()
	row.add_child(_status_label)

	return margin


func _create_bridge_tab() -> Control:
	var content := _create_scroll_content()

	var status_section := _create_section(_tr("bridge_status_section"))
	content.add_child(status_section)
	status_section.add_child(_paragraph(_tr("bridge_status_desc")))

	status_section.add_child(_create_address_box(
		_tr("ai_connection_address"),
		_get_gateway_endpoint(),
		_tr("btn_copy_ai_address"),
		true
	))
	status_section.add_child(_create_address_box(
		_tr("editor_service_address"),
		_get_bridge_url(),
		_tr("btn_copy_editor_address"),
		false
	))

	var connection_row := HBoxContainer.new()
	connection_row.add_theme_constant_override("separation", int(_scaled(8)))
	status_section.add_child(connection_row)
	var connection_title := Label.new()
	connection_title.text = _tr("connection_count")
	connection_row.add_child(connection_title)
	_connection_label = _muted_label(_tr("connections_none"))
	_connection_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	connection_row.add_child(_connection_label)

	var button_row := HBoxContainer.new()
	button_row.add_theme_constant_override("separation", int(_scaled(8)))
	status_section.add_child(button_row)

	var start_button := _button(_tr("btn_start_bridge"))
	start_button.pressed.connect(_on_start_pressed)
	button_row.add_child(start_button)

	var stop_button := _button(_tr("btn_stop_bridge"))
	stop_button.pressed.connect(_on_stop_pressed)
	button_row.add_child(stop_button)

	var copy_button := _button(_tr("btn_copy_gateway"))
	copy_button.pressed.connect(func(): _copy_to_clipboard(_get_gateway_endpoint(), _tr("ai_connection_address_plain")))
	status_section.add_child(copy_button)

	var settings_section := _create_section(_tr("bridge_settings_section"))
	content.add_child(settings_section)
	var settings_grid := GridContainer.new()
	settings_grid.columns = 2
	settings_grid.add_theme_constant_override("h_separation", int(_scaled(12)))
	settings_grid.add_theme_constant_override("v_separation", int(_scaled(8)))
	settings_section.add_child(settings_grid)

	_add_grid_label(settings_grid, _tr("bridge_port"))
	_port_spin = SpinBox.new()
	_port_spin.min_value = 1024
	_port_spin.max_value = 65535
	_port_spin.value = int(settings.port)
	_port_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_port_spin.value_changed.connect(_on_port_changed)
	settings_grid.add_child(_port_spin)

	_add_grid_label(settings_grid, _tr("language"))
	_language_option = OptionButton.new()
	_language_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_populate_language_option()
	_language_option.item_selected.connect(_on_language_changed)
	settings_grid.add_child(_language_option)

	_auto_start_check = CheckBox.new()
	_auto_start_check.text = _tr("auto_start")
	_auto_start_check.button_pressed = bool(settings.auto_start)
	_auto_start_check.toggled.connect(_on_auto_start_toggled)
	settings_section.add_child(_auto_start_check)

	_debug_check = CheckBox.new()
	_debug_check.text = _tr("debug_log")
	_debug_check.button_pressed = bool(settings.debug_mode)
	_debug_check.toggled.connect(_on_debug_toggled)
	settings_section.add_child(_debug_check)

	return content.get_parent().get_parent() as Control


func _create_setup_tab() -> Control:
	var content := _create_scroll_content()

	var gateway_section := _create_section(_tr("gateway_start_section"))
	content.add_child(gateway_section)
	gateway_section.add_child(_paragraph(_tr("gateway_start_desc")))
	gateway_section.add_child(_readonly_text(_get_gateway_start_command(false), 54))
	gateway_section.add_child(_readonly_text(_get_gateway_start_command(true), 54))

	var address_section := _create_section(_tr("client_address_section"))
	content.add_child(address_section)
	address_section.add_child(_paragraph(_tr("client_address_desc")))
	address_section.add_child(_readonly_text(_get_gateway_endpoint(), 40))
	var copy_address_button := _button(_tr("btn_copy_gateway"))
	copy_address_button.pressed.connect(func(): _copy_to_clipboard(_get_gateway_endpoint(), _tr("ai_connection_address_plain")))
	address_section.add_child(copy_address_button)

	var instruction_section := _create_section(_tr("agent_instruction"))
	content.add_child(instruction_section)
	instruction_section.add_child(_paragraph(_tr("agent_instruction_desc")))
	instruction_section.add_child(_readonly_text(_get_agent_instruction(), 140))
	var instruction_button := _button(_tr("btn_copy_agent_instruction"))
	instruction_button.pressed.connect(func(): _copy_to_clipboard(_get_agent_instruction(), _tr("agent_instruction")))
	instruction_section.add_child(instruction_button)

	return content.get_parent().get_parent() as Control


func _create_scroll_content() -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", int(_scaled(12)))
	margin.add_theme_constant_override("margin_right", int(_scaled(12)))
	margin.add_theme_constant_override("margin_top", int(_scaled(12)))
	margin.add_theme_constant_override("margin_bottom", int(_scaled(12)))
	scroll.add_child(margin)

	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", int(_scaled(16)))
	margin.add_child(content)
	return content


func _create_section(title: String) -> VBoxContainer:
	var section := VBoxContainer.new()
	section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	section.add_theme_constant_override("separation", int(_scaled(8)))

	var label := Label.new()
	label.text = title
	label.add_theme_color_override("font_color", Color(0.82, 0.82, 0.82))
	section.add_child(label)
	return section


func _button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.custom_minimum_size.y = _scaled(32)
	return button


func _centered(control: Control) -> CenterContainer:
	var container := CenterContainer.new()
	container.add_child(control)
	return container


func _paragraph(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("font_color", Color(0.62, 0.62, 0.62))
	return label


func _value_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.add_theme_color_override("font_color", Color(0.42, 0.72, 1.0))
	return label


func _create_address_box(title: String, value: String, copy_text: String, is_gateway: bool) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", int(_scaled(4)))

	var label := Label.new()
	label.text = title
	box.add_child(label)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", int(_scaled(8)))
	box.add_child(row)

	var field := LineEdit.new()
	field.text = value
	field.editable = false
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(field)

	var copy_button := Button.new()
	copy_button.text = copy_text
	copy_button.custom_minimum_size.y = _scaled(30)
	copy_button.pressed.connect(func():
		var source = _tr("ai_connection_address_plain") if is_gateway else _tr("editor_service_address_plain")
		_copy_to_clipboard(field.text, source)
	)
	row.add_child(copy_button)

	if is_gateway:
		_gateway_url_label = field
	else:
		_bridge_url_label = field
	return box


func _muted_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", Color(0.62, 0.62, 0.62))
	return label


func _add_grid_label(grid: GridContainer, text: String) -> void:
	var label := Label.new()
	label.text = text
	grid.add_child(label)


func _readonly_text(text: String, height: float) -> TextEdit:
	var edit := TextEdit.new()
	edit.text = text
	edit.editable = false
	edit.custom_minimum_size.y = _scaled(height)
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.scroll_fit_content_height = true
	edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	return edit


func _populate_language_option() -> void:
	var languages = _i18n.get_available_languages()
	var current_lang = _i18n.get_language()
	var index := 0
	for lang_code in languages:
		var label = _tr("language_%s" % lang_code)
		_language_option.add_item(label, index)
		_language_option.set_item_metadata(index, lang_code)
		if lang_code == current_lang:
			_language_option.select(index)
		index += 1


func _get_bridge_url() -> String:
	return "ws://%s:%d/bridge" % [settings.host, int(settings.port)]


func _get_gateway_endpoint() -> String:
	var endpoint_from_file = _read_gateway_endpoint_file()
	if not endpoint_from_file.is_empty():
		return endpoint_from_file
	return "http://%s:%d/mcp" % [settings.host, int(settings.gateway_port)]


func _get_gateway_start_command(auto_port: bool) -> String:
	var command = "uv run godot-bridge-gateway --project %s" % _shell_quote(_get_project_path())
	if auto_port:
		command += " --auto-port"
	return command


func _get_project_path() -> String:
	return ProjectSettings.globalize_path("res://")


func _shell_quote(value: String) -> String:
	return "\"%s\"" % str(value).replace("\\", "\\\\").replace("\"", "\\\"")


func _read_gateway_endpoint_file() -> String:
	if not FileAccess.file_exists(GATEWAY_ENDPOINT_PATH):
		return ""
	var file = FileAccess.open(GATEWAY_ENDPOINT_PATH, FileAccess.READ)
	if not file:
		return ""
	var content = file.get_as_text()
	file.close()
	var json := JSON.new()
	if json.parse(content) != OK:
		return ""
	var data = json.get_data()
	if not data is Dictionary:
		return ""
	return str(data.get("mcp_url", ""))


func _get_agent_instruction() -> String:
	return _tr("agent_instruction_template") % [
		_get_gateway_endpoint(),
		_get_gateway_start_command(false),
		_get_gateway_start_command(true),
	]


func _copy_to_clipboard(text: String, source: String) -> void:
	DisplayServer.clipboard_set(text)
	_show_message(_tr("msg_copied") % source)


func _show_message(message: String) -> void:
	print("[Godot Bridge] %s" % message)
	var dialog := AcceptDialog.new()
	dialog.title = _tr("dialog_title")
	dialog.dialog_text = message
	if dock:
		dock.add_child(dialog)
		dialog.popup_centered()
		dialog.confirmed.connect(func(): dialog.queue_free())


func _update_status_ui() -> void:
	if not dock:
		return
	var running: bool = bridge_server != null and bridge_server.is_running()
	var color := Color(0.2, 0.78, 0.28) if running else Color(0.9, 0.32, 0.28)
	if _status_indicator:
		_status_indicator.color = color
	if _status_label:
		_status_label.text = _tr("status_running") if running else _tr("status_stopped")
		_status_label.add_theme_color_override("font_color", color)
	if _bridge_url_label:
		_bridge_url_label.text = _get_bridge_url()
	if _gateway_url_label:
		_gateway_url_label.text = _get_gateway_endpoint()
	_update_connection_count()


func _update_connection_count() -> void:
	if not _connection_label or not bridge_server:
		return
	var count: int = bridge_server.get_connection_count()
	_connection_label.text = _tr("connections_none") if count == 0 else _tr("connections_count") % count


func _on_server_started() -> void:
	_update_status_ui()


func _on_server_stopped() -> void:
	_update_status_ui()


func _on_start_pressed() -> void:
	if not bridge_server:
		return
	settings.port = int(_port_spin.value) if _port_spin else int(settings.port)
	bridge_server.set_port(settings.port)
	bridge_server.start()
	_save_settings()
	_update_status_ui()


func _on_stop_pressed() -> void:
	if bridge_server:
		bridge_server.stop()
	_update_status_ui()


func _on_port_changed(value: float) -> void:
	settings.port = int(value)
	if bridge_server:
		bridge_server.set_port(settings.port)
	_save_settings()
	_update_status_ui()


func _on_auto_start_toggled(pressed: bool) -> void:
	settings.auto_start = pressed
	_save_settings()


func _on_debug_toggled(pressed: bool) -> void:
	settings.debug_mode = pressed
	if bridge_server:
		bridge_server.set_debug_mode(pressed)
	_save_settings()


func _on_language_changed(index: int) -> void:
	var lang_code = _language_option.get_item_metadata(index)
	if _i18n:
		_i18n.set_language(lang_code)
		settings.language = lang_code
		_save_settings()
		call_deferred("_rebuild_dock")


func _rebuild_dock() -> void:
	var current_tab := 0
	if _tab_container:
		current_tab = _tab_container.current_tab

	_tab_container = null
	_status_label = null
	_status_indicator = null
	_bridge_url_label = null
	_gateway_url_label = null
	_connection_label = null
	_port_spin = null
	_auto_start_check = null
	_debug_check = null
	_language_option = null
	if dock and is_instance_valid(dock):
		remove_control_from_docks(dock)
		dock.queue_free()
		dock = null

	await get_tree().process_frame
	_create_dock()
	if _tab_container:
		_tab_container.current_tab = current_tab
	call_deferred("_update_status_ui")


func _ensure_bridge_token() -> void:
	if typeof(settings.bridge_token) == TYPE_STRING and not settings.bridge_token.is_empty():
		_write_bridge_token_file()
		return

	if FileAccess.file_exists(BRIDGE_TOKEN_PATH):
		var existing = FileAccess.open(BRIDGE_TOKEN_PATH, FileAccess.READ)
		if existing:
			settings.bridge_token = existing.get_as_text().strip_edges()
			existing.close()
			if not settings.bridge_token.is_empty():
				_save_settings()
				return

	settings.bridge_token = _generate_bridge_token()
	_save_settings()
	_write_bridge_token_file()


func _generate_bridge_token() -> String:
	randomize()
	var token_parts := PackedStringArray()
	for _index in range(4):
		token_parts.append(str(randi()))
	return "-".join(token_parts)


func _write_bridge_token_file() -> void:
	var file = FileAccess.open(BRIDGE_TOKEN_PATH, FileAccess.WRITE)
	if file:
		file.store_string(settings.bridge_token)
		file.close()


func _load_settings() -> void:
	if not FileAccess.file_exists(SETTINGS_PATH):
		return
	var file = FileAccess.open(SETTINGS_PATH, FileAccess.READ)
	if not file:
		return
	var parser := JSON.new()
	if parser.parse(file.get_as_text()) == OK:
		var data = parser.get_data()
		if data is Dictionary:
			settings.merge(data, true)
	file.close()


func _save_settings() -> void:
	var file = FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(settings, "\t"))
		file.close()


func get_bridge_server():
	return bridge_server


func start_bridge() -> void:
	_on_start_pressed()


func stop_bridge() -> void:
	_on_stop_pressed()
