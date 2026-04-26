@tool
extends Node
class_name GodotBridgeServer

## Godot editor bridge for the FastMCP gateway.
## Exposes a local WebSocket API for listing and executing editor tools.

const SlimTools = preload("tools/slim_tools.gd")

signal server_started
signal server_stopped
signal client_connected
signal client_disconnected
signal request_received(method: String, params: Dictionary)

const SERVER_NAME = "godot-bridge-bridge"
const SERVER_VERSION = "1.1.0"
const EVENT_BUFFER_LIMIT = 200

var _tcp_server: TCPServer
var _port: int = 3000
var _host: String = "127.0.0.1"
var _running: bool = false
var _debug_mode: bool = false
var _bridge_token: String = ""
var _clients: Array[Dictionary] = []
var _next_client_id: int = 1
var _events: Array[Dictionary] = []

var _tools: Dictionary = {}
var _tool_definitions: Array[Dictionary] = []
var _disabled_tools: Array = []
var _debugger_helper: RefCounted = null


func _ready() -> void:
	_ensure_tcp_server()
	_register_tools()


func _process(_delta: float) -> void:
	if not _running:
		return
	_accept_pending_clients()
	_poll_clients()


func initialize(port: int, host: String, debug: bool, bridge_token: String = "") -> void:
	_port = port
	_host = host if host in ["127.0.0.1", "localhost"] else "127.0.0.1"
	_debug_mode = debug
	_bridge_token = bridge_token


func start() -> bool:
	if _running:
		return true

	_ensure_tcp_server()
	var error = _tcp_server.listen(_port, _host)
	if error != OK:
		push_error("[MCP] Failed to start bridge on port %d: %s" % [_port, error_string(error)])
		return false

	_running = true
	print("[MCP] Bridge started on ws://%s:%d/bridge" % [_host, _port])
	_emit_event("bridge.started", {"host": _host, "port": _port})
	server_started.emit()
	return true


func stop() -> void:
	if not _running:
		return

	for client in _clients:
		var ws: WebSocketPeer = client.get("ws")
		if ws:
			ws.close(1001, "Bridge stopped")
	_clients.clear()

	if _tcp_server:
		_tcp_server.stop()
	_running = false
	print("[MCP] Bridge stopped")
	_emit_event("bridge.stopped", {})
	server_stopped.emit()


func is_running() -> bool:
	return _running


func _ensure_tcp_server() -> void:
	if not _tcp_server:
		_tcp_server = TCPServer.new()


func set_port(port: int) -> void:
	_port = port


func set_debug_mode(debug: bool) -> void:
	_debug_mode = debug


func get_connection_count() -> int:
	var count := 0
	for client in _clients:
		var ws: WebSocketPeer = client.get("ws")
		if ws and ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			count += 1
	return count


func set_disabled_tools(disabled: Array) -> void:
	_disabled_tools = []
	for tool_name in disabled:
		var normalized = str(tool_name)
		if _has_tool_definition(normalized):
			_disabled_tools.append(normalized)


func get_disabled_tools() -> Array:
	return _disabled_tools


func is_tool_enabled(tool_name: String) -> bool:
	return not (tool_name in _disabled_tools)


func get_tools_by_category() -> Dictionary:
	var result: Dictionary = {}
	for category in _tools:
		var executor = _tools[category]
		result[category] = executor.get_tools()
	return result


func get_enabled_tools() -> Array[Dictionary]:
	var enabled: Array[Dictionary] = []
	for tool_def in _tool_definitions:
		if is_tool_enabled(tool_def["name"]):
			enabled.append(tool_def)
	return enabled


func get_tools() -> Array[Dictionary]:
	return get_enabled_tools()


func execute(tool_name: String, args: Dictionary) -> Dictionary:
	return _execute_bridge_tool(tool_name, args)


func set_debugger_helper(helper: RefCounted) -> void:
	_debugger_helper = helper
	if _debugger_helper and _debugger_helper.has_signal("runtime_event"):
		if not _debugger_helper.runtime_event.is_connected(_on_runtime_event):
			_debugger_helper.runtime_event.connect(_on_runtime_event)
	for executor in _tools.values():
		if executor.has_method("set_debugger_helper"):
			executor.set_debugger_helper(helper)


func _register_tools() -> void:
	_tools.clear()
	_tools["godot"] = SlimTools.new()
	if _debugger_helper:
		_tools["godot"].set_debugger_helper(_debugger_helper)

	_tool_definitions.clear()
	for category in _tools:
		var executor = _tools[category]
		for tool_def in executor.get_tools():
			tool_def["name"] = "godot_%s" % tool_def["name"]
			_tool_definitions.append(tool_def)

	set_disabled_tools(_disabled_tools)

	if _debug_mode:
		print("[MCP] Registered %d tools" % _tool_definitions.size())


func _accept_pending_clients() -> void:
	while _tcp_server.is_connection_available():
		var tcp := _tcp_server.take_connection()
		if not tcp:
			return
		var ws := WebSocketPeer.new()
		ws.supported_protocols = PackedStringArray(["godot-bridge"])
		ws.heartbeat_interval = 10.0
		var err := ws.accept_stream(tcp)
		if err != OK:
			tcp.disconnect_from_host()
			push_warning("[MCP] WebSocket handshake failed: %s" % error_string(err))
			continue
		var client := {
			"id": _next_client_id,
			"ws": ws,
			"authenticated": _bridge_token.is_empty(),
		}
		_next_client_id += 1
		_clients.append(client)
		_emit_event("client.connected", {"id": client["id"], "authenticated": client["authenticated"]})
		client_connected.emit()


func _poll_clients() -> void:
	var remove: Array[Dictionary] = []
	for client in _clients:
		var ws: WebSocketPeer = client.get("ws")
		if not ws:
			remove.append(client)
			continue
		ws.poll()
		var state := ws.get_ready_state()
		if state == WebSocketPeer.STATE_OPEN:
			while ws.get_available_packet_count() > 0:
				var packet := ws.get_packet()
				_handle_packet(client, packet.get_string_from_utf8())
		elif state == WebSocketPeer.STATE_CLOSED:
			remove.append(client)

	for client in remove:
		_clients.erase(client)
		_emit_event("client.disconnected", {"id": client.get("id", 0)})
		client_disconnected.emit()


func _handle_packet(client: Dictionary, text: String) -> void:
	var json := JSON.new()
	var err := json.parse(text)
	if err != OK:
		_send_error(client, "", "Parse error: %s" % json.get_error_message())
		return
	var message = json.get_data()
	if not message is Dictionary:
		_send_error(client, "", "Invalid message")
		return

	var message_type := str(message.get("type", "request"))
	if message_type == "auth":
		_handle_auth(client, message)
		return
	if message_type != "request":
		_send_error(client, str(message.get("id", "")), "Unsupported message type: %s" % message_type)
		return

	var request_id := str(message.get("id", ""))
	var method := str(message.get("method", ""))
	var params = message.get("params", {})
	if not params is Dictionary:
		_send_error(client, request_id, "params must be an object")
		return

	if not bool(client.get("authenticated", false)) and method != "health":
		_send_error(client, request_id, "Unauthorized")
		return

	request_received.emit(method, params)
	var result := _dispatch_request(method, params)
	var ok: bool = not (result is Dictionary and result.get("success") == false)
	_send_response(client, request_id, ok, result, str(result.get("error", "")) if result is Dictionary else "")


func _handle_auth(client: Dictionary, message: Dictionary) -> void:
	var request_id := str(message.get("id", ""))
	var token := str(message.get("token", ""))
	var ok: bool = _bridge_token.is_empty() or token == _bridge_token
	client["authenticated"] = ok
	_emit_event("client.authenticated", {"id": client.get("id", 0), "ok": ok})
	_send_response(client, request_id, ok, {"authenticated": ok}, "Unauthorized" if not ok else "")


func _dispatch_request(method: String, params: Dictionary) -> Dictionary:
	match method:
		"health":
			return _create_health_response()
		"list_tools":
			return _create_tools_list_response()
		"execute":
			var tool_name := str(params.get("name", ""))
			var arguments = params.get("arguments", {})
			if tool_name.is_empty():
				return {"success": false, "error": "Missing tool name"}
			if not arguments is Dictionary:
				return {"success": false, "error": "Arguments must be an object"}
			return _execute_bridge_tool(tool_name, arguments)
		"events":
			return {"success": true, "events": _events.duplicate()}
	return {"success": false, "error": "Unknown method: %s" % method}


func _send_response(client: Dictionary, request_id: String, ok: bool, result, error: String = "") -> void:
	var envelope := {
		"type": "response",
		"id": request_id,
		"ok": ok,
		"result": result if ok else null,
		"error": error if not ok else "",
	}
	_send_message(client, envelope)


func _send_error(client: Dictionary, request_id: String, error: String) -> void:
	_send_response(client, request_id, false, null, error)


func _send_message(client: Dictionary, data: Dictionary) -> void:
	var ws: WebSocketPeer = client.get("ws")
	if not ws or ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	ws.send_text(JSON.stringify(_sanitize_for_json(data)))


func _broadcast_event(event: Dictionary) -> void:
	for client in _clients:
		if bool(client.get("authenticated", false)):
			_send_message(client, {"type": "event", "event": event["event"], "payload": event["payload"], "time": event["time"]})


func _emit_event(event_name: String, payload: Dictionary) -> void:
	var event := {
		"event": event_name,
		"payload": payload,
		"time": Time.get_unix_time_from_system(),
	}
	_events.append(event)
	while _events.size() > EVENT_BUFFER_LIMIT:
		_events.pop_front()
	_broadcast_event(event)


func _on_runtime_event(event_name: String, payload: Dictionary) -> void:
	_emit_event(event_name, payload)


func _execute_bridge_tool(tool_name: String, arguments: Dictionary) -> Dictionary:
	if not is_tool_enabled(tool_name):
		return {"success": false, "error": "Tool '%s' is disabled or unavailable" % tool_name}

	var parts = tool_name.split("_", true, 1)
	if parts.size() != 2 or parts[0] != "godot":
		return {"success": false, "error": "Invalid tool name: %s" % tool_name}

	var category = "godot"
	var actual_tool_name = parts[1]
	if not _tools.has(category):
		return {"success": false, "error": "Unknown tool category: %s" % category}

	var result = _tools[category].execute(actual_tool_name, arguments)
	_emit_event("tool.executed", {"tool": tool_name, "action": arguments.get("action", ""), "success": result.get("success", false)})
	return result


func _has_tool_definition(tool_name: String) -> bool:
	for tool_def in _tool_definitions:
		if str(tool_def.get("name", "")) == tool_name:
			return true
	return false


func _create_health_response() -> Dictionary:
	return {
		"status": "ok",
		"server": SERVER_NAME,
		"version": SERVER_VERSION,
		"mode": "bridge",
		"transport": "websocket",
		"running": _running,
		"connections": get_connection_count(),
		"auth": not _bridge_token.is_empty(),
	}


func _create_tools_list_response() -> Dictionary:
	return {"tools": get_enabled_tools()}


func _sanitize_for_json(value):
	match typeof(value):
		TYPE_DICTIONARY:
			var result := {}
			for key in value:
				result[str(key)] = _sanitize_for_json(value[key])
			return result
		TYPE_ARRAY:
			var result := []
			for item in value:
				result.append(_sanitize_for_json(item))
			return result
		TYPE_FLOAT:
			if is_nan(value):
				return 0.0
			if is_inf(value):
				return 999999999.0 if value > 0 else -999999999.0
			return value
		TYPE_STRING_NAME, TYPE_NODE_PATH:
			return str(value)
		TYPE_OBJECT:
			if value == null:
				return null
			return str(value)
		TYPE_VECTOR2, TYPE_VECTOR3, TYPE_VECTOR4:
			return str(value)
		TYPE_COLOR:
			return {"r": value.r, "g": value.g, "b": value.b, "a": value.a}
		TYPE_NIL:
			return null
		_:
			return value
