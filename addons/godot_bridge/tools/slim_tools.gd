@tool
extends "res://addons/godot_bridge/tools/bridge_toolkit.gd"

## Slim Godot MCP tool surface.
## Exposes the small, high-value Bridge API used by the FastMCP gateway.

var _debugger_helper: RefCounted = null

const ACTIONS := {
	"scene": ["get_current", "open", "save", "save_as", "create", "close", "reload", "tree", "selection", "select", "play_main", "play_current", "play_custom", "stop_playing"],
	"node": ["find", "info", "children", "create", "delete", "duplicate", "instantiate", "reparent", "reorder", "get_property", "set_property", "list_properties", "transform", "visibility"],
	"script": ["create", "read", "write", "info", "attach", "detach", "open", "open_at_line", "list_open"],
	"resource": ["list", "search", "info", "dependencies", "create", "copy", "move", "delete", "reload", "uid", "refresh_uids", "assign_texture"],
	"project": ["info", "get_setting", "set_setting", "list_settings", "input_list", "input_add", "input_remove", "autoload_list", "autoload_add", "autoload_remove"],
	"editor": ["status", "main_screen", "set_main_screen", "filesystem_scan", "filesystem_reimport", "select_file", "selected_files", "inspect_node", "inspect_resource", "classdb"],
	"debug": ["sessions", "set_breakpoint", "send_message", "captured_messages", "clear_messages"],
	"view": ["capture_editor_viewport"]
}


func set_debugger_helper(helper: RefCounted) -> void:
	_debugger_helper = helper


func get_tools() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for name in ACTIONS:
		result.append({
			"name": name,
			"actions": ACTIONS[name],
		})
	return result


func execute(tool_name: String, args: Dictionary) -> Dictionary:
	match tool_name:
		"scene":
			return _execute_scene(args)
		"node":
			return _execute_node(args)
		"script":
			return _execute_script(args)
		"resource":
			return _execute_resource(args)
		"project":
			return _execute_project(args)
		"editor":
			return _execute_editor(args)
		"debug":
			return _execute_debug(args)
		"view":
			return _execute_view(args)
		_:
			return _error("Unknown tool: godot_%s" % tool_name)


func _description_for(name: String) -> String:
	match name:
		"scene":
			return "Scene editing and playback. Actions: %s" % ", ".join(ACTIONS[name])
		"node":
			return "Node query and scene-tree editing with scene-relative paths. Actions: %s" % ", ".join(ACTIONS[name])
		"script":
			return "GDScript file management, node attachment, and editor opening. Actions: %s" % ", ".join(ACTIONS[name])
		"resource":
			return "Resource query, creation, movement, UID refresh, and texture assignment. Actions: %s" % ", ".join(ACTIONS[name])
		"project":
			return "Project settings, input actions, and autoload management. Actions: %s" % ", ".join(ACTIONS[name])
		"editor":
			return "Editor state, filesystem refresh, inspector, and ClassDB query. Actions: %s" % ", ".join(ACTIONS[name])
		"debug":
			return "Debugger sessions, breakpoints, and captured godot_bridge debugger messages. Actions: %s" % ", ".join(ACTIONS[name])
		"view":
			return "Capture editor 2D or 3D viewport screenshots to user://godot_bridge/screenshots."
	return ""


func _execute_scene(args: Dictionary) -> Dictionary:
	var action = args.get("action", "")
	var ei = _get_editor_interface()
	if not ei:
		return _error("EditorInterface is not available")

	match action:
		"get_current":
			var root = _get_edited_scene_root()
			if not root:
				return _success({"has_scene": false})
			return _success({"has_scene": true, "name": str(root.name), "path": str(root.scene_file_path), "root_type": root.get_class(), "node_count": _count_nodes(root)})
		"open":
			var path = _normalize_res_path(args.get("path", ""))
			if path.is_empty():
				return _error("path is required")
			ei.open_scene_from_path(path)
			return _success({"path": path}, "Scene opened")
		"save":
			var err = ei.save_scene()
			if err != OK:
				return _error("Failed to save scene: %s" % error_string(err))
			return _success({"path": str(_get_edited_scene_root().scene_file_path) if _get_edited_scene_root() else ""}, "Scene saved")
		"save_as":
			var save_path = _normalize_res_path(args.get("path", ""))
			if save_path.is_empty():
				return _error("path is required")
			ei.save_scene_as(save_path)
			return _success({"path": save_path}, "Scene saved")
		"create":
			return _scene_create(args)
		"close":
			var close_err = ei.close_scene()
			if close_err != OK:
				return _error("Failed to close scene: %s" % error_string(close_err))
			return _success(null, "Scene closed")
		"reload":
			var root = _get_edited_scene_root()
			if not root or str(root.scene_file_path).is_empty():
				return _error("No saved scene is open")
			ei.reload_scene_from_path(root.scene_file_path)
			return _success({"path": root.scene_file_path}, "Scene reloaded")
		"tree":
			var tree_root = _get_edited_scene_root()
			if not tree_root:
				return _error("No scene open")
			return _success(_node_to_dict(tree_root, true, args.get("depth", 8)))
		"selection":
			var selection = _get_selection()
			var nodes: Array[Dictionary] = []
			if selection:
				for node in selection.get_selected_nodes():
					nodes.append(_node_to_dict(node, false))
			return _success({"count": nodes.size(), "nodes": nodes})
		"select":
			var selection = _get_selection()
			if not selection:
				return _error("Editor selection is not available")
			selection.clear()
			for path in args.get("paths", []):
				var node = _find_node_by_path(str(path))
				if node:
					selection.add_node(node)
			return _success({"paths": args.get("paths", [])}, "Selection updated")
		"play_main":
			ei.play_main_scene()
			return _success(null, "Main scene started")
		"play_current":
			ei.play_current_scene()
			return _success(null, "Current scene started")
		"play_custom":
			var custom_path = _normalize_res_path(args.get("path", ""))
			if custom_path.is_empty():
				return _error("path is required")
			ei.play_custom_scene(custom_path)
			return _success({"path": custom_path}, "Custom scene started")
		"stop_playing":
			ei.stop_playing_scene()
			return _success(null, "Scene playback stopped")
	return _error("Unknown godot_scene action: %s" % action)


func _scene_create(args: Dictionary) -> Dictionary:
	var root_type = args.get("root_type", "Node")
	var scene_name = args.get("name", "NewScene")
	if not ClassDB.class_exists(root_type) or not ClassDB.is_parent_class(root_type, "Node"):
		return _error("Invalid root_type: %s" % root_type)
	var root = ClassDB.instantiate(root_type)
	if not root:
		return _error("Failed to create root node")
	root.name = scene_name
	var packed = PackedScene.new()
	var err = packed.pack(root)
	if err != OK:
		root.queue_free()
		return _error("Failed to pack scene: %s" % error_string(err))
	var path = _normalize_res_path(args.get("path", "res://%s.tscn" % scene_name.to_snake_case()))
	var save_err = ResourceSaver.save(packed, path)
	root.queue_free()
	if save_err != OK:
		return _error("Failed to save new scene: %s" % error_string(save_err))
	_get_editor_interface().open_scene_from_path(path)
	return _success({"path": path, "name": scene_name, "root_type": root_type}, "Scene created")


func _execute_node(args: Dictionary) -> Dictionary:
	var action = args.get("action", "")
	match action:
		"find":
			return _node_find(args)
		"info":
			var node = _required_node(args.get("path", ""))
			return node if node is Dictionary else _success(_node_to_dict(node, args.get("include_children", false), args.get("depth", 2)))
		"children":
			var parent = _required_node(args.get("path", ""))
			if parent is Dictionary:
				return parent
			var children: Array[Dictionary] = []
			for child in parent.get_children():
				children.append(_node_to_dict(child, false))
			return _success({"path": _get_scene_path(parent), "count": children.size(), "children": children})
		"create":
			return _node_create(args)
		"delete":
			var del_node = _required_node(args.get("path", ""))
			if del_node is Dictionary:
				return del_node
			if del_node == _get_edited_scene_root():
				return _error("Refusing to delete the scene root")
			return _node_delete(del_node)
		"duplicate":
			return _node_duplicate(args)
		"instantiate":
			return _node_instantiate(args)
		"reparent":
			return _node_reparent(args)
		"reorder":
			var node = _required_node(args.get("path", ""))
			if node is Dictionary:
				return node
			var index = int(args.get("index", 0))
			var parent = node.get_parent()
			var old_index = node.get_index()
			var undo_redo = _get_undo_redo()
			if undo_redo:
				undo_redo.create_action("Godot Bridge: Reorder Node", UndoRedo.MERGE_DISABLE, node)
				undo_redo.add_do_method(parent, "move_child", node, index)
				undo_redo.add_undo_method(parent, "move_child", node, old_index)
				undo_redo.commit_action()
			else:
				parent.move_child(node, index)
				_mark_scene_unsaved()
			return _success({"path": _get_scene_path(node), "index": index}, "Node reordered")
		"get_property":
			var get_node = _required_node(args.get("path", ""))
			if get_node is Dictionary:
				return get_node
			var property = args.get("property", "")
			if property.is_empty():
				return _error("property is required")
			return _success({"path": _get_scene_path(get_node), "property": property, "value": _serialize_value(get_node.get(property))})
		"set_property":
			var set_node = _required_node(args.get("path", ""))
			if set_node is Dictionary:
				return set_node
			var set_property = args.get("property", "")
			if set_property.is_empty():
				return _error("property is required")
			if set_property == "script":
				if args.get("value") == null or str(args.get("value", "")).is_empty():
					_set_script_undoable(set_node, null, "Detach Script")
					return _success({"node": _get_scene_path(set_node)}, "Script detached")
				return _attach_script_to_node(set_node, str(args.get("value")), "Set Script")
			_set_property_undoable(set_node, set_property, _deserialize_value(args.get("value"), set_node.get(set_property)), "Set Property")
			return _success({"path": _get_scene_path(set_node), "property": set_property}, "Property set")
		"list_properties":
			var list_node = _required_node(args.get("path", ""))
			if list_node is Dictionary:
				return list_node
			return _success({"path": _get_scene_path(list_node), "properties": _property_list(list_node, args.get("filter", ""))})
		"transform":
			return _node_transform(args)
		"visibility":
			return _node_visibility(args)
	return _error("Unknown godot_node action: %s" % action)


func _node_find(args: Dictionary) -> Dictionary:
	var root = _get_edited_scene_root()
	if not root:
		return _error("No scene open")
	var pattern = str(args.get("pattern", "*"))
	var type_name = str(args.get("type", ""))
	var results: Array[Dictionary] = []
	_collect_matching_nodes(root, pattern, type_name, results)
	return _success({"count": results.size(), "nodes": results})


func _collect_matching_nodes(node: Node, pattern: String, type_name: String, results: Array[Dictionary]) -> void:
	var name_matches = pattern.is_empty() or pattern == "*" or str(node.name).match(pattern) or str(node.name).contains(pattern.replace("*", ""))
	var type_matches = type_name.is_empty() or node.is_class(type_name) or node.get_class() == type_name
	if name_matches and type_matches:
		results.append(_node_to_dict(node, false))
	for child in node.get_children():
		_collect_matching_nodes(child, pattern, type_name, results)


func _node_create(args: Dictionary) -> Dictionary:
	var type_name = args.get("type", "Node")
	if not ClassDB.class_exists(type_name) or not ClassDB.is_parent_class(type_name, "Node"):
		return _error("Invalid node type: %s" % type_name)
	var parent = _find_node_by_path(args.get("parent_path", "")) if not str(args.get("parent_path", "")).is_empty() else _get_edited_scene_root()
	if not parent:
		return _error("Parent not found")
	var node = ClassDB.instantiate(type_name)
	if not node:
		return _error("Failed to create node")
	node.name = args.get("name", type_name)
	_add_child_undoable(parent, node, "Create Node")
	return _success(_node_to_dict(node, false), "Node created")


func _node_delete(node: Node) -> Dictionary:
	var del_path = _get_scene_path(node)
	var parent = node.get_parent()
	if not parent:
		return _error("Node has no parent: %s" % del_path)
	var old_index = node.get_index()
	var old_owner = node.owner
	var undo_redo = _get_undo_redo()
	if undo_redo:
		undo_redo.create_action("Godot Bridge: Delete Node", UndoRedo.MERGE_DISABLE, node)
		undo_redo.add_do_method(parent, "remove_child", node)
		undo_redo.add_undo_method(parent, "add_child", node, true)
		undo_redo.add_undo_method(parent, "move_child", node, old_index)
		undo_redo.add_undo_method(node, "set_owner", old_owner)
		undo_redo.add_undo_reference(node)
		undo_redo.commit_action()
	else:
		node.queue_free()
		_mark_scene_unsaved()
	return _success({"path": del_path}, "Node deleted")


func _node_duplicate(args: Dictionary) -> Dictionary:
	var node = _required_node(args.get("path", ""))
	if node is Dictionary:
		return node
	var duplicate = node.duplicate()
	if args.has("name"):
		duplicate.name = args.get("name")
	_add_child_undoable(node.get_parent(), duplicate, "Duplicate Node")
	return _success(_node_to_dict(duplicate, false), "Node duplicated")


func _node_instantiate(args: Dictionary) -> Dictionary:
	var scene_path = _normalize_res_path(args.get("scene_path", ""))
	if scene_path.is_empty():
		return _error("scene_path is required")
	var packed = load(scene_path) as PackedScene
	if not packed:
		return _error("Failed to load PackedScene: %s" % scene_path)
	var parent = _find_node_by_path(args.get("parent_path", "")) if not str(args.get("parent_path", "")).is_empty() else _get_edited_scene_root()
	if not parent:
		return _error("Parent not found")
	var instance = packed.instantiate()
	if args.has("name"):
		instance.name = args.get("name")
	_add_child_undoable(parent, instance, "Instantiate Scene")
	return _success(_node_to_dict(instance, false), "Scene instantiated")


func _node_reparent(args: Dictionary) -> Dictionary:
	var node = _required_node(args.get("path", ""))
	if node is Dictionary:
		return node
	var new_parent = _required_node(args.get("new_parent", ""))
	if new_parent is Dictionary:
		return new_parent
	var had_global := false
	var old_global = null
	if node is Node3D:
		old_global = node.global_transform
		had_global = true
	elif node is Node2D:
		old_global = node.global_transform
		had_global = true
	var old_parent = node.get_parent()
	var old_index = node.get_index()
	var old_owner = node.owner
	var undo_redo = _get_undo_redo()
	if undo_redo:
		undo_redo.create_action("Godot Bridge: Reparent Node", UndoRedo.MERGE_DISABLE, node)
		undo_redo.add_do_method(old_parent, "remove_child", node)
		undo_redo.add_do_method(new_parent, "add_child", node, true)
		undo_redo.add_do_method(node, "set_owner", _get_edited_scene_root())
		if args.get("keep_global", true) and had_global:
			if node is Node3D:
				undo_redo.add_do_property(node, "global_transform", old_global)
			elif node is Node2D:
				undo_redo.add_do_property(node, "global_transform", old_global)
		undo_redo.add_undo_method(new_parent, "remove_child", node)
		undo_redo.add_undo_method(old_parent, "add_child", node, true)
		undo_redo.add_undo_method(old_parent, "move_child", node, old_index)
		undo_redo.add_undo_method(node, "set_owner", old_owner)
		undo_redo.commit_action()
	else:
		old_parent.remove_child(node)
		new_parent.add_child(node)
		if args.get("keep_global", true) and had_global:
			if node is Node3D:
				node.global_transform = old_global
			elif node is Node2D:
				node.global_transform = old_global
		node.owner = _get_edited_scene_root()
		_mark_scene_unsaved()
	return _success({"path": _get_scene_path(node), "parent": _get_scene_path(new_parent)}, "Node reparented")


func _node_transform(args: Dictionary) -> Dictionary:
	var node = _required_node(args.get("path", ""))
	if node is Dictionary:
		return node
	if not (node is Node2D or node is Node3D):
		return _error("Transform is only available for Node2D and Node3D")
	if args.get("mode", "set") == "get":
		return _success({"path": _get_scene_path(node), "position": _serialize_value(node.get("position")), "rotation": _serialize_value(node.get("rotation")), "scale": _serialize_value(node.get("scale"))})
	var changes := {}
	if args.has("position"):
		changes["position"] = _deserialize_value(args.get("position"), node.get("position"))
	if args.has("rotation"):
		changes["rotation"] = _deserialize_value(args.get("rotation"), node.get("rotation"))
	if args.has("rotation_degrees"):
		changes["rotation_degrees"] = _deserialize_value(args.get("rotation_degrees"), node.get("rotation_degrees"))
	if args.has("scale"):
		changes["scale"] = _deserialize_value(args.get("scale"), node.get("scale"))
	_set_properties_undoable(node, changes, "Transform")
	return _success(_node_to_dict(node, false), "Transform updated")


func _node_visibility(args: Dictionary) -> Dictionary:
	var node = _required_node(args.get("path", ""))
	if node is Dictionary:
		return node
	if not (node is CanvasItem or node is Node3D):
		return _error("Visibility is only available for CanvasItem and Node3D")
	var changes := {}
	if args.has("visible"):
		changes["visible"] = bool(args.get("visible"))
	if args.has("z_index") and node is CanvasItem:
		changes["z_index"] = int(args.get("z_index"))
	_set_properties_undoable(node, changes, "Visibility")
	var visible_value = null
	if node is CanvasItem or node is Node3D:
		visible_value = node.visible
	return _success({"path": _get_scene_path(node), "visible": visible_value}, "Visibility updated")


func _execute_script(args: Dictionary) -> Dictionary:
	var action = args.get("action", "")
	var path = _normalize_res_path(args.get("path", ""))
	match action:
		"create":
			if path.is_empty():
				return _error("path is required")
			var source = "extends %s\n" % args.get("extends", "Node")
			if not str(args.get("class_name", "")).is_empty():
				source += "class_name %s\n" % args.get("class_name")
			source += "\nfunc _ready() -> void:\n\tpass\n"
			return _write_text_file(path, source, "Script created")
		"read":
			return _read_text_file(path)
		"write":
			return _write_text_file(path, args.get("content", ""), "Script written")
		"info":
			var script = load(path) as Script
			if not script:
				return _error("Failed to load script: %s" % path)
			return _success({"path": path, "base_type": script.get_instance_base_type(), "source_code_size": script.source_code.length() if script is GDScript else 0})
		"attach":
			var node = _required_node(args.get("node_path", ""))
			if node is Dictionary:
				return node
			var attach_path = _normalize_res_path(args.get("script_path", path))
			if attach_path.is_empty():
				return _error("path or script_path is required")
			return _attach_script_to_node(node, attach_path, "Attach Script")
		"detach":
			var detach_node = _required_node(args.get("node_path", ""))
			if detach_node is Dictionary:
				return detach_node
			_set_script_undoable(detach_node, null, "Detach Script")
			return _success({"node": _get_scene_path(detach_node)}, "Script detached")
		"open", "open_at_line":
			var open_script = load(path) as Script
			if not open_script:
				return _error("Failed to load script: %s" % path)
			_get_editor_interface().edit_script(open_script, int(args.get("line", -1)))
			return _success({"path": path, "line": args.get("line", -1)}, "Script opened")
		"list_open":
			var editor = _get_editor_interface().get_script_editor()
			var scripts: Array[String] = []
			if editor:
				for script in editor.get_open_scripts():
					if script is Script:
						scripts.append(str(script.resource_path))
			return _success({"count": scripts.size(), "scripts": scripts})
	return _error("Unknown godot_script action: %s" % action)


func _execute_resource(args: Dictionary) -> Dictionary:
	var action = args.get("action", "")
	match action:
		"list":
			return _resource_list(_normalize_res_path(args.get("path", "res://")), args.get("type", ""), args.get("recursive", true))
		"search":
			return _resource_search(args.get("pattern", ""), args.get("type", ""))
		"info":
			return _resource_info(_normalize_res_path(args.get("path", "")))
		"dependencies":
			var path = _normalize_res_path(args.get("path", ""))
			return _success({"path": path, "dependencies": Array(ResourceLoader.get_dependencies(path))})
		"create":
			return _resource_create(args)
		"copy":
			return _copy_or_move_resource(args.get("source", ""), args.get("dest", ""), false)
		"move":
			return _copy_or_move_resource(args.get("source", ""), args.get("dest", ""), true)
		"delete":
			var delete_path = _normalize_res_path(args.get("path", ""))
			var err = DirAccess.remove_absolute(ProjectSettings.globalize_path(delete_path))
			if err != OK:
				return _error("Failed to delete resource: %s" % error_string(err))
			_scan_filesystem()
			return _success({"path": delete_path}, "Resource deleted")
		"reload":
			ResourceLoader.load(_normalize_res_path(args.get("path", "")), "", ResourceLoader.CACHE_MODE_REPLACE)
			return _success({"path": _normalize_res_path(args.get("path", ""))}, "Resource reloaded")
		"uid":
			var uid_path = _normalize_res_path(args.get("path", ""))
			return _success({"path": uid_path, "uid": ResourceUID.path_to_uid(uid_path)})
		"refresh_uids":
			return _refresh_resource_uids(_normalize_res_path(args.get("root", "res://")))
		"assign_texture":
			return _assign_texture(args)
	return _error("Unknown godot_resource action: %s" % action)


func _execute_project(args: Dictionary) -> Dictionary:
	var action = args.get("action", "")
	match action:
		"info":
			return _success({"name": ProjectSettings.get_setting("application/config/name", "Untitled"), "path": ProjectSettings.globalize_path("res://"), "main_scene": ProjectSettings.get_setting("application/run/main_scene", "")})
		"get_setting":
			var setting = args.get("setting", "")
			if setting.is_empty():
				return _error("setting is required")
			return _success({"setting": setting, "value": _serialize_value(ProjectSettings.get_setting(setting, null))})
		"set_setting":
			var set_setting = args.get("setting", "")
			if set_setting.is_empty():
				return _error("setting is required")
			ProjectSettings.set_setting(set_setting, args.get("value"))
			ProjectSettings.save()
			return _success({"setting": set_setting}, "Project setting saved")
		"list_settings":
			var prefix = args.get("prefix", args.get("category", ""))
			var settings: Dictionary = {}
			for prop in ProjectSettings.get_property_list():
				var name = str(prop.name)
				if prefix.is_empty() or name.begins_with(prefix):
					settings[name] = _serialize_value(ProjectSettings.get_setting(name))
			return _success({"count": settings.size(), "settings": settings})
		"input_list":
			return _input_list()
		"input_add":
			return _input_add(args)
		"input_remove":
			return _input_remove(args)
		"autoload_list":
			return _autoload_list()
		"autoload_add":
			return _autoload_add(args.get("name", ""), _normalize_res_path(args.get("path", "")))
		"autoload_remove":
			return _autoload_remove(args.get("name", ""))
	return _error("Unknown godot_project action: %s" % action)


func _execute_editor(args: Dictionary) -> Dictionary:
	var action = args.get("action", "")
	var ei = _get_editor_interface()
	if not ei:
		return _error("EditorInterface is not available")
	match action:
		"status":
			return _success({"version": Engine.get_version_info(), "playing": ei.is_playing_scene(), "playing_scene": ei.get_playing_scene(), "open_scenes": Array(ei.get_open_scenes()), "edited_scene": str(_get_edited_scene_root().scene_file_path) if _get_edited_scene_root() else ""})
		"main_screen":
			return _success({"screen": "unknown"})
		"set_main_screen":
			ei.set_main_screen_editor(args.get("screen", "2D"))
			return _success({"screen": args.get("screen", "2D")}, "Main screen changed")
		"filesystem_scan":
			_scan_filesystem()
			return _success(null, "Filesystem scan started")
		"filesystem_reimport":
			var fs = _get_filesystem()
			if not fs:
				return _error("Editor filesystem is not available")
			var paths := PackedStringArray()
			for item in args.get("paths", []):
				paths.append(_normalize_res_path(str(item)))
			fs.reimport_files(paths)
			return _success({"paths": Array(paths)}, "Files reimported")
		"select_file":
			ei.select_file(_normalize_res_path(args.get("path", "")))
			return _success({"path": _normalize_res_path(args.get("path", ""))}, "File selected")
		"selected_files":
			return _success({"paths": Array(ei.get_selected_paths())})
		"inspect_node":
			var node = _required_node(args.get("path", ""))
			if node is Dictionary:
				return node
			ei.inspect_object(node)
			return _success({"path": _get_scene_path(node)}, "Node inspected")
		"inspect_resource":
			var res = load(_normalize_res_path(args.get("path", "")))
			if not res:
				return _error("Failed to load resource")
			ei.edit_resource(res)
			return _success({"path": res.resource_path}, "Resource inspected")
		"classdb":
			return _classdb_query(args)
	return _error("Unknown godot_editor action: %s" % action)


func _execute_debug(args: Dictionary) -> Dictionary:
	if not _debugger_helper:
		return _error("Debugger helper is not registered")
	var action = args.get("action", "")
	match action:
		"sessions":
			return _success({"sessions": _debugger_helper.call("get_session_info")})
		"set_breakpoint":
			var result = _debugger_helper.call("set_breakpoint", int(args.get("session_id", 0)), _normalize_res_path(args.get("path", "")), int(args.get("line", 1)), bool(args.get("enabled", true)))
			return _success(result, "Breakpoint updated")
		"send_message":
			var result = _debugger_helper.call("send_debug_message", int(args.get("session_id", 0)), args.get("message", ""), args.get("data", []))
			return _success(result, "Debug message sent")
		"captured_messages":
			return _success({"messages": _debugger_helper.call("get_captured_messages", int(args.get("limit", 100)))})
		"clear_messages":
			_debugger_helper.call("clear_captured_messages")
			return _success(null, "Captured messages cleared")
	return _error("Unknown godot_debug action: %s" % action)


func _execute_view(args: Dictionary) -> Dictionary:
	if args.get("action", "") != "capture_editor_viewport":
		return _error("Unknown godot_view action: %s" % args.get("action", ""))
	var ei = _get_editor_interface()
	if not ei:
		return _error("EditorInterface is not available")
	var mode = str(args.get("mode", "3d")).to_lower()
	var viewport = ei.get_editor_viewport_2d() if mode == "2d" else ei.get_editor_viewport_3d(int(args.get("index", 0)))
	if not viewport:
		return _error("Editor viewport is not available")
	var image = viewport.get_texture().get_image()
	if not image:
		return _error("Failed to read viewport image")
	var dir = "user://godot_bridge/screenshots"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var path = "%s/editor_%s_%d.png" % [dir, mode, int(Time.get_unix_time_from_system())]
	var err = image.save_png(path)
	if err != OK:
		return _error("Failed to save screenshot: %s" % error_string(err))
	var data = {"path": path, "absolute_path": ProjectSettings.globalize_path(path), "width": image.get_width(), "height": image.get_height(), "mode": mode}
	if args.get("include_base64", false):
		var file = FileAccess.open(path, FileAccess.READ)
		if file:
			data["base64"] = Marshalls.raw_to_base64(file.get_buffer(file.get_length()))
			file.close()
	return _success(data, "Viewport captured")


func _required_node(path: String):
	var root = _get_edited_scene_root()
	if root and str(path) == str(root.name):
		return root
	var node = _find_node_by_path(path)
	if not node:
		return _error("Node not found: %s" % path)
	return node


func _normalize_res_path(path: String) -> String:
	path = str(path)
	if path.is_empty():
		return ""
	if path.begins_with("res://") or path.begins_with("user://") or path.begins_with("uid://"):
		return path
	return "res://" + path


func _count_nodes(node: Node) -> int:
	var count = 1
	for child in node.get_children():
		count += _count_nodes(child)
	return count


func _mark_scene_unsaved() -> void:
	var ei = _get_editor_interface()
	if ei:
		ei.mark_scene_as_unsaved()


func _get_undo_redo():
	var ei = _get_editor_interface()
	return ei.get_editor_undo_redo() if ei and ei.has_method("get_editor_undo_redo") else null


func _add_child_undoable(parent: Node, child: Node, action_name: String) -> void:
	var root = _get_edited_scene_root()
	var undo_redo = _get_undo_redo()
	if undo_redo:
		undo_redo.create_action("Godot Bridge: %s" % action_name, UndoRedo.MERGE_DISABLE, root if root else parent)
		undo_redo.add_do_method(parent, "add_child", child, true)
		if root:
			undo_redo.add_do_method(child, "set_owner", root)
		undo_redo.add_do_reference(child)
		undo_redo.add_undo_method(parent, "remove_child", child)
		undo_redo.commit_action()
	else:
		parent.add_child(child)
		if root:
			child.owner = root
		_mark_scene_unsaved()


func _set_property_undoable(object: Object, property: String, value, action_name: String) -> void:
	var changes := {}
	changes[property] = value
	_set_properties_undoable(object, changes, action_name)


func _set_properties_undoable(object: Object, changes: Dictionary, action_name: String) -> void:
	if changes.is_empty():
		return
	var undo_redo = _get_undo_redo()
	if undo_redo:
		undo_redo.create_action("Godot Bridge: %s" % action_name, UndoRedo.MERGE_DISABLE, object)
		for property in changes:
			undo_redo.add_do_property(object, property, changes[property])
			undo_redo.add_undo_property(object, property, object.get(property))
		undo_redo.commit_action()
	else:
		for property in changes:
			object.set(property, changes[property])
		_mark_scene_unsaved()


func _set_script_undoable(node: Node, script: Script, action_name: String) -> void:
	var old_script = node.get_script()
	var undo_redo = _get_undo_redo()
	if undo_redo:
		undo_redo.create_action("Godot Bridge: %s" % action_name, UndoRedo.MERGE_DISABLE, node)
		undo_redo.add_do_method(node, "set_script", script)
		undo_redo.add_undo_method(node, "set_script", old_script)
		undo_redo.commit_action()
	else:
		node.set_script(script)
		_mark_scene_unsaved()


func _attach_script_to_node(node: Node, script_path: String, action_name: String) -> Dictionary:
	var attach_path = _normalize_res_path(script_path)
	if attach_path.is_empty():
		return _error("script_path is required")
	var script = load(attach_path) as Script
	if not script:
		return _error("Failed to load script: %s" % attach_path)
	var validation_error = _validate_script_for_node(node, script)
	if not validation_error.is_empty():
		return _error(validation_error)

	_set_script_undoable(node, script, action_name)
	var attached_script = node.get_script()
	var attached_path = ""
	if attached_script and attached_script is Resource:
		attached_path = str(attached_script.resource_path)
	if attached_path != attach_path:
		return _error("Script attach did not persist on node: %s" % _get_scene_path(node), {"expected": attach_path, "actual": attached_path})
	return _success({"node": _get_scene_path(node), "script": attached_path}, "Script attached")


func _validate_script_for_node(node: Node, script: Script) -> String:
	var base_type = str(script.get_instance_base_type())
	if base_type.is_empty():
		return "Script has no valid instance base type. Check for parse errors before attaching."
	if ClassDB.class_exists(base_type) and not node.is_class(base_type):
		return "Script base type '%s' is not compatible with node '%s' of type '%s'." % [base_type, _get_scene_path(node), node.get_class()]
	return ""


func _property_list(object: Object, filter: String = "") -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for prop in object.get_property_list():
		var name = str(prop.name)
		if filter.is_empty() or name.contains(filter):
			result.append({"name": name, "type": prop.type, "type_name": _type_to_string(prop.type), "hint": prop.hint, "hint_string": str(prop.hint_string), "usage": prop.usage})
	return result


func _read_text_file(path: String) -> Dictionary:
	if path.is_empty():
		return _error("path is required")
	var file = FileAccess.open(path, FileAccess.READ)
	if not file:
		return _error("Failed to open file: %s" % path)
	var content = file.get_as_text()
	file.close()
	return _success({"path": path, "content": content})


func _write_text_file(path: String, content: String, message: String) -> Dictionary:
	if path.is_empty():
		return _error("path is required")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var file = FileAccess.open(path, FileAccess.WRITE)
	if not file:
		return _error("Failed to open file for writing: %s" % path)
	file.store_string(content)
	file.close()
	_scan_filesystem()
	return _success({"path": path}, message)


func _scan_filesystem() -> void:
	var fs = _get_filesystem()
	if fs:
		fs.scan()


func _resource_list(path: String, type_filter: String, recursive: bool) -> Dictionary:
	var fs = _get_filesystem()
	if not fs:
		return _error("Editor filesystem is not available")
	var dir = fs.get_filesystem_path(path)
	if not dir:
		return _error("Directory not found: %s" % path)
	var resources: Array[Dictionary] = []
	_collect_resources(dir, type_filter, recursive, resources)
	return _success({"path": path, "count": resources.size(), "resources": resources})


func _collect_resources(dir: EditorFileSystemDirectory, type_filter: String, recursive: bool, results: Array[Dictionary]) -> void:
	for i in dir.get_file_count():
		var file_type = str(dir.get_file_type(i))
		if type_filter.is_empty() or file_type == type_filter:
			results.append({"path": str(dir.get_file_path(i)), "type": file_type, "name": str(dir.get_file(i))})
	if recursive:
		for i in dir.get_subdir_count():
			_collect_resources(dir.get_subdir(i), type_filter, recursive, results)


func _resource_search(pattern: String, type_filter: String) -> Dictionary:
	if pattern.is_empty():
		return _error("pattern is required")
	var listed = _resource_list("res://", type_filter, true)
	if listed.get("success") == false:
		return listed
	var matches: Array[Dictionary] = []
	for item in listed.get("data", {}).get("resources", []):
		var name = str(item.get("name", ""))
		if name.match(pattern) or name.contains(pattern.replace("*", "")):
			matches.append(item)
	return _success({"pattern": pattern, "count": matches.size(), "resources": matches})


func _resource_info(path: String) -> Dictionary:
	if path.is_empty():
		return _error("path is required")
	if not ResourceLoader.exists(path):
		return _error("Resource not found: %s" % path)
	var resource = load(path)
	if not resource:
		return _error("Failed to load resource")
	var info = {"path": path, "type": resource.get_class(), "resource_name": resource.resource_name}
	if resource is Texture2D:
		info["width"] = resource.get_width()
		info["height"] = resource.get_height()
	if resource is PackedScene:
		info["node_count"] = resource.get_state().get_node_count()
	if resource is Script:
		info["base_type"] = resource.get_instance_base_type()
	return _success(info)


func _resource_create(args: Dictionary) -> Dictionary:
	var type_name = args.get("type", "Resource")
	var path = _normalize_res_path(args.get("path", ""))
	if path.is_empty():
		return _error("path is required")
	var resource: Resource = null
	match type_name:
		"GDScript":
			resource = GDScript.new()
			resource.source_code = "extends Node\n"
		"Resource":
			resource = Resource.new()
		_:
			if ClassDB.class_exists(type_name) and ClassDB.is_parent_class(type_name, "Resource"):
				resource = ClassDB.instantiate(type_name)
	if not resource:
		return _error("Unsupported resource type: %s" % type_name)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var err = ResourceSaver.save(resource, path)
	if err != OK:
		return _error("Failed to save resource: %s" % error_string(err))
	_scan_filesystem()
	return _success({"path": path, "type": type_name}, "Resource created")


func _copy_or_move_resource(source: String, dest: String, move: bool) -> Dictionary:
	source = _normalize_res_path(source)
	dest = _normalize_res_path(dest)
	if source.is_empty() or dest.is_empty():
		return _error("source and dest are required")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dest.get_base_dir()))
	var err = DirAccess.rename_absolute(ProjectSettings.globalize_path(source), ProjectSettings.globalize_path(dest)) if move else DirAccess.copy_absolute(ProjectSettings.globalize_path(source), ProjectSettings.globalize_path(dest))
	if err != OK:
		return _error("File operation failed: %s" % error_string(err))
	_scan_filesystem()
	return _success({"source": source, "dest": dest}, "Resource moved" if move else "Resource copied")


func _refresh_resource_uids(root: String) -> Dictionary:
	var listed = _resource_list(root, "", true)
	if listed.get("success") == false:
		return listed
	var saved = 0
	for item in listed.get("data", {}).get("resources", []):
		var path = str(item.get("path", ""))
		var res = load(path)
		if res:
			if ResourceSaver.save(res, path) == OK:
				saved += 1
	_scan_filesystem()
	return _success({"root": root, "saved": saved}, "Resource UIDs refreshed")


func _assign_texture(args: Dictionary) -> Dictionary:
	var texture = load(_normalize_res_path(args.get("texture_path", "")))
	if not texture:
		return _error("Failed to load texture")
	var node = _required_node(args.get("node_path", ""))
	if node is Dictionary:
		return node
	var property = args.get("property", "texture")
	_set_property_undoable(node, property, texture, "Assign Texture")
	return _success({"node": _get_scene_path(node), "texture": texture.resource_path, "property": property}, "Texture assigned")


func _input_list() -> Dictionary:
	var actions: Array[Dictionary] = []
	for prop in ProjectSettings.get_property_list():
		var name = str(prop.name)
		if name.begins_with("input/"):
			var data = ProjectSettings.get_setting(name)
			actions.append({"name": name.substr(6), "deadzone": data.get("deadzone", 0.5) if data is Dictionary else 0.5, "event_count": data.get("events", []).size() if data is Dictionary else 0})
	return _success({"count": actions.size(), "actions": actions})


func _input_add(args: Dictionary) -> Dictionary:
	var name = str(args.get("name", ""))
	if name.is_empty():
		return _error("name is required")
	var setting_path = "input/" + name
	var action_data = ProjectSettings.get_setting(setting_path, null)
	if not action_data is Dictionary:
		action_data = {"deadzone": float(args.get("deadzone", 0.5)), "events": []}

	var event = _input_event_from_args(args)
	if event is Dictionary:
		return event
	if event:
		var events = action_data.get("events", [])
		events.append(event)
		action_data["events"] = events

	ProjectSettings.set_setting(setting_path, action_data)
	ProjectSettings.save()
	return _success({"name": name, "event_count": action_data.get("events", []).size()}, "Input action added")


func _input_remove(args: Dictionary) -> Dictionary:
	var name = str(args.get("name", ""))
	if name.is_empty():
		return _error("name is required")
	var setting_path = "input/" + name
	if args.has("index"):
		var action_data = ProjectSettings.get_setting(setting_path, null)
		if not action_data is Dictionary:
			return _error("Input action not found: %s" % name)
		var index = int(args.get("index", -1))
		var events = action_data.get("events", [])
		if index < 0 or index >= events.size():
			return _error("index is out of range")
		events.remove_at(index)
		action_data["events"] = events
		ProjectSettings.set_setting(setting_path, action_data)
		ProjectSettings.save()
		return _success({"name": name, "removed_index": index, "event_count": events.size()}, "Input binding removed")
	ProjectSettings.set_setting(setting_path, null)
	ProjectSettings.save()
	return _success({"name": name}, "Input action removed")


func _input_event_from_args(args: Dictionary):
	var event_type = str(args.get("type", ""))
	if event_type.is_empty():
		return null
	match event_type:
		"key":
			var key_event = InputEventKey.new()
			if args.has("keycode"):
				key_event.keycode = int(args.get("keycode"))
			else:
				var key = str(args.get("key", ""))
				if key.is_empty():
					return _error("key or keycode is required for key input")
				key_event.keycode = OS.find_keycode_from_string(key)
			return key_event
		"mouse", "mouse_button":
			var mouse_event = InputEventMouseButton.new()
			var button = args.get("button", args.get("button_index", "left"))
			if button is String:
				match str(button).to_lower():
					"left":
						mouse_event.button_index = MOUSE_BUTTON_LEFT
					"right":
						mouse_event.button_index = MOUSE_BUTTON_RIGHT
					"middle":
						mouse_event.button_index = MOUSE_BUTTON_MIDDLE
					_:
						return _error("Unknown mouse button: %s" % button)
			else:
				mouse_event.button_index = int(button)
			return mouse_event
		"joypad_button", "joy_button":
			var joy_button_event = InputEventJoypadButton.new()
			joy_button_event.button_index = int(args.get("button", args.get("button_index", 0)))
			return joy_button_event
		"joypad_axis", "joy_axis":
			var joy_axis_event = InputEventJoypadMotion.new()
			joy_axis_event.axis = int(args.get("axis", 0))
			joy_axis_event.axis_value = float(args.get("axis_value", 1.0))
			return joy_axis_event
	return _error("Unknown input type: %s" % event_type)


func _autoload_list() -> Dictionary:
	var autoloads: Array[Dictionary] = []
	for prop in ProjectSettings.get_property_list():
		var name = str(prop.name)
		if name.begins_with("autoload/"):
			autoloads.append({"name": name.substr(9), "path": ProjectSettings.get_setting(name), "order": ProjectSettings.get_order(name)})
	return _success({"count": autoloads.size(), "autoloads": autoloads})


func _autoload_add(name: String, path: String) -> Dictionary:
	if name.is_empty() or path.is_empty():
		return _error("name and path are required")
	var setting = "autoload/" + name
	ProjectSettings.set_setting(setting, "*" + path)
	ProjectSettings.save()
	return _success({"name": name, "path": path}, "Autoload added")


func _autoload_remove(name: String) -> Dictionary:
	if name.is_empty():
		return _error("name is required")
	ProjectSettings.set_setting("autoload/" + name, null)
	ProjectSettings.save()
	return _success({"name": name}, "Autoload removed")


func _classdb_query(args: Dictionary) -> Dictionary:
	var query = args.get("query", args.get("class_name", ""))
	var mode = args.get("mode", "info")
	var no_inheritance = not bool(args.get("include_inherited", true))
	match mode:
		"list":
			return _success({"classes": ClassDB.get_class_list()})
		"methods":
			return _success({"class": query, "methods": ClassDB.class_get_method_list(query, no_inheritance)})
		"properties":
			return _success({"class": query, "properties": ClassDB.class_get_property_list(query, no_inheritance)})
		"signals":
			return _success({"class": query, "signals": ClassDB.class_get_signal_list(query, no_inheritance)})
		"exists":
			return _success({"class": query, "exists": ClassDB.class_exists(query)})
	if query.is_empty():
		return _error("query or class_name is required")
	return _success({"class": query, "exists": ClassDB.class_exists(query), "can_instantiate": ClassDB.can_instantiate(query) if ClassDB.class_exists(query) else false, "parent": ClassDB.get_parent_class(query) if ClassDB.class_exists(query) else ""})
