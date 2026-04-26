@tool
extends RefCounted
class_name MCPLocalization

const DEFAULT_LANGUAGE = "en"
const LANGUAGE_LABELS := {
	"en": "English",
	"zh_CN": "简体中文",
}
const LANGUAGE_SCRIPTS := {
	"en": "lang_en.gd",
	"zh_CN": "lang_zh_CN.gd",
}

static var _shared

var _language: String = DEFAULT_LANGUAGE
var _catalogs: Dictionary = {}


static func get_instance():
	if not _shared:
		_shared = load("res://addons/godot_bridge/i18n/localization.gd").new()
		_shared._load_catalogs()
	return _shared


static func reset_instance() -> void:
	_shared = null


static func translate(key: String) -> String:
	return get_instance().get_text(key)


func set_language(language_code: String) -> void:
	if LANGUAGE_LABELS.has(language_code):
		_language = language_code


func get_language() -> String:
	return _language


func get_available_languages() -> Dictionary:
	return LANGUAGE_LABELS.duplicate()


func get_text(key: String) -> String:
	var active = _catalogs.get(_language, {})
	if active is Dictionary and active.has(key):
		return str(active[key])

	var fallback = _catalogs.get(DEFAULT_LANGUAGE, {})
	if fallback is Dictionary and fallback.has(key):
		return str(fallback[key])

	return key


func _load_catalogs() -> void:
	var folder: String = get_script().resource_path.get_base_dir()
	for language_code in LANGUAGE_SCRIPTS:
		var script_path: String = "%s/%s" % [folder, LANGUAGE_SCRIPTS[language_code]]
		var catalog: Dictionary = _read_catalog(script_path)
		if not catalog.is_empty():
			_catalogs[language_code] = catalog
	_language = _system_language()


func _read_catalog(script_path: String) -> Dictionary:
	if not ResourceLoader.exists(script_path):
		return {}
	var script = ResourceLoader.load(script_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if script and script.has_method("get_translations"):
		var catalog = script.get_translations()
		return catalog if catalog is Dictionary else {}
	return {}


func _system_language() -> String:
	var locale: String = OS.get_locale()
	if LANGUAGE_LABELS.has(locale):
		return locale
	if locale.begins_with("zh"):
		return "zh_CN"
	return DEFAULT_LANGUAGE
