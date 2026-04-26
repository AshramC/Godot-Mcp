extends Node

const CAPTURE_NAME := "godot_bridge"

var _registered := false


func _ready() -> void:
	_register_capture()


func _exit_tree() -> void:
	if _registered and EngineDebugger.has_capture(CAPTURE_NAME):
		EngineDebugger.unregister_message_capture(CAPTURE_NAME)
	_registered = false


func _register_capture() -> void:
	if not EngineDebugger.is_active():
		return
	if EngineDebugger.has_capture(CAPTURE_NAME):
		return
	EngineDebugger.register_message_capture(CAPTURE_NAME, Callable(self, "_capture"))
	_registered = true
	EngineDebugger.send_message("godot_bridge:ready", [{"path": get_path(), "time": Time.get_unix_time_from_system()}])


func _capture(message: String, data: Array) -> bool:
	if message != "request":
		return false
	if data.is_empty() or not data[0] is Dictionary:
		_send_response("", false, null, "Invalid godot_bridge request")
		return true

	var request: Dictionary = data[0]
	var request_id := str(request.get("id", ""))
	var action := str(request.get("action", ""))
	var payload = request.get("payload", {})
	if not payload is Dictionary:
		_send_response(request_id, false, null, "payload must be an object")
		return true

	var result := _execute_action(action, payload)
	_send_response(request_id, result.get("success", false), result.get("data"), str(result.get("error", "")))
	return true


func _execute_action(action: String, payload: Dictionary) -> Dictionary:
	match action:
		"ping":
			return _ok({"pong": true, "root": str(get_tree().root.get_path())})
		"status":
			return _ok({"active": EngineDebugger.is_active(), "registered": _registered, "root": str(get_tree().root.get_path())})
		"tree":
			var root = _node_from_payload(payload)
			if root is Dictionary:
				return root
			return _ok(_node_to_dict(root, int(payload.get("depth", 6))))
		"get_property":
			var node = _node_from_payload(payload)
			if node is Dictionary:
				return node
			var property := str(payload.get("property", ""))
			if property.is_empty():
				return _error("property is required")
			return _ok({"path": _node_path(node), "property": property, "value": _to_json_value(node.get(property))})
		"set_property":
			var node = _node_from_payload(payload)
			if node is Dictionary:
				return node
			var property := str(payload.get("property", ""))
			if property.is_empty():
				return _error("property is required")
			node.set(property, _decode_value(payload.get("value"), node.get(property)))
			return _ok({"path": _node_path(node), "property": property, "value": _to_json_value(node.get(property))})
		"call_method":
			var node = _node_from_payload(payload)
			if node is Dictionary:
				return node
			var method := str(payload.get("method", ""))
			if method.is_empty():
				return _error("method is required")
			var call_args: Array = payload.get("args", [])
			var result = node.callv(method, call_args)
			return _ok({"path": _node_path(node), "method": method, "result": _to_json_value(result)})
		"eval":
			return _eval_expression(str(payload.get("expression", "")))
		"exec":
			return _exec_code(str(payload.get("code", "")))
		"screenshot":
			return _capture_screenshot(bool(payload.get("include_base64", false)))
	return _error("Unknown runtime action: %s" % action)


func _node_from_payload(payload: Dictionary):
	var path := str(payload.get("path", "/root"))
	var node := get_node_or_null(path)
	if not node and not path.begins_with("/root"):
		node = get_tree().root.get_node_or_null(path)
	if not node:
		return _error("Node not found: %s" % path)
	return node


func _node_to_dict(node: Node, depth: int) -> Dictionary:
	var data := {
		"name": str(node.name),
		"type": node.get_class(),
		"path": _node_path(node),
		"child_count": node.get_child_count(),
	}
	if node is CanvasItem or node is Node3D:
		data["visible"] = node.visible
	if node is Node2D:
		data["position"] = _to_json_value(node.position)
	elif node is Node3D:
		data["position"] = _to_json_value(node.position)
	if depth > 0:
		var children := []
		for child in node.get_children():
			children.append(_node_to_dict(child, depth - 1))
		data["children"] = children
	return data


func _node_path(node: Node) -> String:
	return str(node.get_path())


func _eval_expression(source: String) -> Dictionary:
	if source.is_empty():
		return _error("expression is required")
	var expression := Expression.new()
	var err := expression.parse(source, PackedStringArray(["root", "tree"]))
	if err != OK:
		return _error(expression.get_error_text())
	var value = expression.execute([get_tree().root, get_tree()], self, false)
	if expression.has_execute_failed():
		return _error(expression.get_error_text())
	return _ok({"result": _to_json_value(value)})


func _exec_code(source: String) -> Dictionary:
	if source.is_empty():
		return _error("code is required")
	var script := GDScript.new()
	script.source_code = "extends RefCounted\n\nfunc _run(ctx: Dictionary):\n%s\n" % _indent_code(source)
	var err := script.reload()
	if err != OK:
		return _error("Failed to compile code: %s" % error_string(err))
	var instance = script.new()
	var context := {"root": get_tree().root, "tree": get_tree(), "bridge": self}
	var result = instance.call("_run", context)
	return _ok({"result": _to_json_value(result)})


func _indent_code(source: String) -> String:
	var lines := source.split("\n")
	var output := ""
	for line in lines:
		output += "\t%s\n" % line
	if output.strip_edges().is_empty():
		output = "\tpass\n"
	return output


func _capture_screenshot(include_base64: bool) -> Dictionary:
	var viewport := get_tree().root
	var image := viewport.get_texture().get_image()
	if not image:
		return _error("Failed to read root viewport")
	image.clear_mipmaps()
	var dir := "user://godot_bridge/runtime_screenshots"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var path := "%s/runtime_%d.png" % [dir, int(Time.get_unix_time_from_system())]
	var err := image.save_png(path)
	if err != OK:
		return _error("Failed to save screenshot: %s" % error_string(err))
	var data := {"path": path, "absolute_path": ProjectSettings.globalize_path(path), "width": image.get_width(), "height": image.get_height()}
	if include_base64:
		var file := FileAccess.open(path, FileAccess.READ)
		if file:
			data["base64"] = Marshalls.raw_to_base64(file.get_buffer(file.get_length()))
			file.close()
	return _ok(data)


func _send_response(request_id: String, success: bool, data, error: String) -> void:
	if not EngineDebugger.is_active():
		return
	EngineDebugger.send_message("godot_bridge:response", [{
		"id": request_id,
		"success": success,
		"data": _to_json_value(data),
		"error": error,
		"time": Time.get_unix_time_from_system(),
	}])


func _ok(data = null) -> Dictionary:
	return {"success": true, "data": data}


func _error(message: String) -> Dictionary:
	return {"success": false, "error": message}


func _decode_value(value, reference):
	if value is String:
		var text: String = value.strip_edges()
		if text.begins_with("{") or text.begins_with("["):
			var parsed = JSON.parse_string(text)
			if parsed != null:
				value = parsed
	match typeof(reference):
		TYPE_VECTOR2:
			if value is Dictionary:
				return Vector2(float(value.get("x", reference.x)), float(value.get("y", reference.y)))
		TYPE_VECTOR3:
			if value is Dictionary:
				return Vector3(float(value.get("x", reference.x)), float(value.get("y", reference.y)), float(value.get("z", reference.z)))
		TYPE_COLOR:
			if value is Dictionary:
				return Color(float(value.get("r", reference.r)), float(value.get("g", reference.g)), float(value.get("b", reference.b)), float(value.get("a", reference.a)))
	return value


func _to_json_value(value):
	match typeof(value):
		TYPE_VECTOR2, TYPE_VECTOR2I:
			return {"x": float(value.x), "y": float(value.y)}
		TYPE_VECTOR3, TYPE_VECTOR3I:
			return {"x": float(value.x), "y": float(value.y), "z": float(value.z)}
		TYPE_COLOR:
			return {"r": value.r, "g": value.g, "b": value.b, "a": value.a}
		TYPE_OBJECT:
			if value == null:
				return null
			if value is Node:
				return {"path": str(value.get_path()), "type": value.get_class()}
			if value is Resource and not str(value.resource_path).is_empty():
				return str(value.resource_path)
			return str(value)
		TYPE_ARRAY:
			var items := []
			for item in value:
				items.append(_to_json_value(item))
			return items
		TYPE_DICTIONARY:
			var data := {}
			for key in value:
				data[str(key)] = _to_json_value(value[key])
			return data
		TYPE_STRING_NAME, TYPE_NODE_PATH:
			return str(value)
		TYPE_FLOAT:
			if is_nan(value) or is_inf(value):
				return 0.0
	return value
