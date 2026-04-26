@tool
extends RefCounted

## Shared editor helpers for the local Bridge executor.
## The Gateway owns MCP schemas; this file only normalizes editor results.


func get_tools() -> Array[Dictionary]:
	return []


func execute(tool_name: String, args: Dictionary) -> Dictionary:
	return bridge_error("未实现的桥接工具: %s" % tool_name)


func bridge_ok(data = null, message: String = "") -> Dictionary:
	var payload: Dictionary = {"success": true}
	if data != null:
		payload["data"] = to_json_value(data)
	if not message.is_empty():
		payload["message"] = message
	return payload


func bridge_error(message: String, data = null, hints: Array = []) -> Dictionary:
	var payload: Dictionary = {
		"success": false,
		"error": message,
	}
	if data != null:
		payload["data"] = to_json_value(data)
	if not hints.is_empty():
		payload["hints"] = hints
	return payload


func _success(data = null, message: String = "") -> Dictionary:
	return bridge_ok(data, message)


func _error(message: String, data = null, hints: Array = []) -> Dictionary:
	return bridge_error(message, data, hints)


func _get_editor_interface() -> EditorInterface:
	if Engine.has_singleton("EditorInterface"):
		return Engine.get_singleton("EditorInterface")
	return null


func _get_edited_scene_root() -> Node:
	var editor := _get_editor_interface()
	return editor.get_edited_scene_root() if editor else null


func _get_selection() -> EditorSelection:
	var editor := _get_editor_interface()
	return editor.get_selection() if editor else null


func _get_filesystem() -> EditorFileSystem:
	var editor := _get_editor_interface()
	return editor.get_resource_filesystem() if editor else null


func _get_scene_path(node: Node) -> String:
	if not node or not node.is_inside_tree():
		return ""

	var root := _get_edited_scene_root()
	if not root:
		return str(node.get_path())
	if node == root:
		return str(root.name)

	var root_path := str(root.get_path())
	var node_path := str(node.get_path())
	var prefix := root_path + "/"
	if node_path.begins_with(prefix):
		return node_path.substr(prefix.length())
	return node_path


func _node_to_dict(node: Node, include_children: bool = false, max_depth: int = 3) -> Dictionary:
	if not node:
		return {}

	var data: Dictionary = {
		"name": str(node.name),
		"type": str(node.get_class()),
		"path": _get_scene_path(node),
		"visible": _read_visible_state(node),
	}

	if node is Node2D:
		data["position"] = _vector2(node.position)
		data["rotation"] = float(node.rotation)
		data["scale"] = _vector2(node.scale)
	elif node is Node3D:
		data["position"] = _vector3(node.position)
		data["rotation"] = _vector3(node.rotation)
		data["scale"] = _vector3(node.scale)

	var script = node.get_script()
	if script and script is Resource:
		data["script"] = str(script.resource_path)

	if include_children and max_depth > 0:
		var children: Array[Dictionary] = []
		for child in node.get_children():
			children.append(_node_to_dict(child, true, max_depth - 1))
		if not children.is_empty():
			data["children"] = children

	return data


func _find_node_by_path(path: String) -> Node:
	var root := _get_edited_scene_root()
	if not root:
		return null

	var requested := str(path)
	if requested.is_empty() or requested == "/" or requested == str(root.name):
		return root
	return root.get_node_or_null(requested)


func _type_to_string(value_type: int) -> String:
	return type_string(value_type)


func _serialize_value(value) -> Variant:
	return to_json_value(value)


func _deserialize_value(value, reference):
	var decoded = _decode_jsonish_value(value)
	match typeof(reference):
		TYPE_VECTOR2:
			return _as_vector2(decoded, reference)
		TYPE_VECTOR2I:
			var v2 := _as_vector2(decoded, reference)
			return Vector2i(int(v2.x), int(v2.y))
		TYPE_VECTOR3:
			return _as_vector3(decoded, reference)
		TYPE_VECTOR3I:
			var v3 := _as_vector3(decoded, reference)
			return Vector3i(int(v3.x), int(v3.y), int(v3.z))
		TYPE_COLOR:
			return _as_color(decoded, reference)
		TYPE_RECT2:
			return _as_rect2(decoded, reference)
		TYPE_OBJECT:
			if decoded is String and decoded.begins_with("res://"):
				var resource = load(decoded)
				return resource if resource else reference
	return decoded


func to_json_value(value) -> Variant:
	match typeof(value):
		TYPE_VECTOR2, TYPE_VECTOR2I:
			return _vector2(value)
		TYPE_VECTOR3, TYPE_VECTOR3I:
			return _vector3(value)
		TYPE_VECTOR4, TYPE_VECTOR4I:
			return {"x": value.x, "y": value.y, "z": value.z, "w": value.w}
		TYPE_COLOR:
			return {"r": value.r, "g": value.g, "b": value.b, "a": value.a}
		TYPE_RECT2, TYPE_RECT2I:
			return {"position": _vector2(value.position), "size": _vector2(value.size)}
		TYPE_TRANSFORM2D:
			return {"x": _vector2(value.x), "y": _vector2(value.y), "origin": _vector2(value.origin)}
		TYPE_TRANSFORM3D:
			return {"basis": to_json_value(value.basis), "origin": _vector3(value.origin)}
		TYPE_BASIS:
			return {"x": _vector3(value.x), "y": _vector3(value.y), "z": _vector3(value.z)}
		TYPE_OBJECT:
			if value == null:
				return null
			if value is Resource and not str(value.resource_path).is_empty():
				return str(value.resource_path)
			return str(value)
		TYPE_ARRAY:
			var items: Array = []
			for item in value:
				items.append(to_json_value(item))
			return items
		TYPE_DICTIONARY:
			var result: Dictionary = {}
			for key in value:
				result[str(key)] = to_json_value(value[key])
			return result
		TYPE_STRING_NAME, TYPE_NODE_PATH:
			return str(value)
		TYPE_FLOAT:
			if is_nan(value) or is_inf(value):
				return 0.0
			return float(value)
	return value


func _read_visible_state(node: Node) -> bool:
	if node is CanvasItem or node is Node3D:
		return bool(node.visible)
	return true


func _vector2(value) -> Dictionary:
	return {"x": float(value.x), "y": float(value.y)}


func _vector3(value) -> Dictionary:
	return {"x": float(value.x), "y": float(value.y), "z": float(value.z)}


func _decode_jsonish_value(value):
	if value is String:
		var text: String = value.strip_edges()
		if text.begins_with("{") or text.begins_with("["):
			var parser := JSON.new()
			if parser.parse(text) == OK:
				return parser.get_data()
	return value


func _as_vector2(value, fallback) -> Vector2:
	if value is Dictionary:
		return Vector2(float(value.get("x", fallback.x)), float(value.get("y", fallback.y)))
	return fallback


func _as_vector3(value, fallback) -> Vector3:
	if value is Dictionary:
		return Vector3(
			float(value.get("x", fallback.x)),
			float(value.get("y", fallback.y)),
			float(value.get("z", fallback.z))
		)
	return fallback


func _as_color(value, fallback: Color) -> Color:
	if value is Dictionary:
		return Color(
			float(value.get("r", fallback.r)),
			float(value.get("g", fallback.g)),
			float(value.get("b", fallback.b)),
			float(value.get("a", fallback.a))
		)
	if value is String and Color.html_is_valid(value):
		return Color.html(value)
	return fallback


func _as_rect2(value, fallback: Rect2) -> Rect2:
	if not value is Dictionary:
		return fallback
	var position = value.get("position", {})
	var size = value.get("size", {})
	if not position is Dictionary or not size is Dictionary:
		return fallback
	return Rect2(_as_vector2(position, fallback.position), _as_vector2(size, fallback.size))
