@tool
extends EditorPlugin
## The Blendkit plugin: settings, logging and the main screen tab. The Client
## connection is ClientConnection, the tab is the gallery.

signal model_format_changed
signal download_dir_changed

const SERVER = "https://blendkit.com"
# [value, label] pairs for the settings dialog and the Format filter
const MODEL_FORMATS = [["blend", "Blender (.blend)"], ["gltf_godot", "glTF (.glb)"]]
const UUID_NAMES = [[ProjectAssets.UUID_NAMES_FULL, "Full"], [ProjectAssets.UUID_NAMES_SHORT, "Short"], [ProjectAssets.UUID_NAMES_STRIP, "Strip"]]
const RESOLUTIONS = [["", "Auto"], ["ORIGINAL", "Original"], ["resolution_4K", "4K"], ["resolution_2K", "2K"], ["resolution_1K", "1K"], ["resolution_0_5K", "0.5K"]]
# Project settings live in project.godot and are shared with the team, editor
# settings stay on this computer. All of them show in Godot's settings dialogs.
const SETTING_DOWNLOAD_DIR = "blendkit/downloads/directory"
const SETTING_MODEL_FORMAT = "blendkit/downloads/model_format"
const SETTING_RESOLUTION = "blendkit/downloads/resolution"
const SETTING_UUID_NAMES = "blendkit/downloads/uuids_in_names"
const SETTING_CLIENT_ENABLED = "blendkit/client/enabled"
const SETTING_PORT = "blendkit/client/port"
const SETTING_LOG_LEVEL = "blendkit/client/log_level"
# Older keys moved to the settings above.
const OLD_SETTINGS = {"blendkit/model_format": SETTING_MODEL_FORMAT, "blendkit/resolution": SETTING_RESOLUTION}
# Godot's enum hints can't hold an empty value, so Auto resolution "" is stored as this.
const RESOLUTION_AUTO = "auto"
# The resolution Auto downloads.
const AUTO_RESOLUTION = "resolution_2K"
const USER_GUIDE_URL = "https://www.blendkit.com/blendkit-in-godot/"
const SOURCES_URL = "https://github.com/BlenderKit/bk_godot"
const ISSUES_URL = "https://github.com/BlenderKit/bk_godot/issues"

const gallery_scene = preload("res://addons/blendkit/ui/gallery/gallery.tscn")
const Auth = preload("res://addons/blendkit/auth.gd")
const BlenderImport = preload("res://addons/blendkit/blender_import.gd")
const ClientBinary = preload("res://addons/blendkit/client_binary.gd")
const ClientConnection = preload("res://addons/blendkit/client_connection.gd")
const GalleryApi = preload("res://addons/blendkit/ui/gallery/gallery_api.gd")
const ProjectAssets = preload("res://addons/blendkit/ui/gallery/project_assets.gd")
const Icons = preload("res://addons/blendkit/ui/icons.gd")


enum LogLevel { ERROR, WARNING, INFO, VERBOSE, DEBUG, TRACE }

var log_level: int = LogLevel.INFO

# The Client reports message_level in Python logging values:
# 0=Debug, 10=Info, 20=Warning, 30=Error, 40=Fatal
static func client_message_log_level(message_level: int) -> LogLevel:
	if message_level >= 30:
		return LogLevel.ERROR
	if message_level >= 20:
		return LogLevel.WARNING
	if message_level >= 10:
		return LogLevel.INFO
	return LogLevel.DEBUG

func bk_log(level: LogLevel, msg: String) -> void:
	if level > log_level:
		return
	var prefix = "Blendkit: " if level == LogLevel.INFO else "Blendkit %s: " % LogLevel.keys()[level]
	var log_msg = prefix + msg
	match level:
		LogLevel.ERROR:
			push_error(log_msg)
		LogLevel.WARNING:
			push_warning(log_msg)
		_:
			print(log_msg)

func log_error(msg: String) -> void:
	bk_log(LogLevel.ERROR, msg)

func log_warning(msg: String) -> void:
	bk_log(LogLevel.WARNING, msg)

func log_info(msg: String) -> void:
	bk_log(LogLevel.INFO, msg)

func log_verbose(msg: String) -> void:
	bk_log(LogLevel.VERBOSE, msg)

func log_debug(msg: String) -> void:
	bk_log(LogLevel.DEBUG, msg)

func log_trace(msg: String) -> void:
	bk_log(LogLevel.TRACE, msg)


var client_enabled := true
var download_dir: String = "res://bk_assets/"
var absolute_download_path: String
var model_format: String = "blend"
var resolution: String = ""
# How much of the UUIDs downloaded folders and files are named with.
var uuid_names: String = ProjectAssets.UUID_NAMES_STRIP
# Godot sets up .blend import when the editor starts, so changes to these
# apply after a restart.
var startup_blend_enabled: bool
var startup_blender_path: String
# Port to start the Client on when none is running
var preferred_port: String = ClientConnection.CLIENT_PORTS[0]
var addon_version: String

var connection: ClientConnection
var auth: Auth
var gallery: Control


func _enter_tree() -> void:
	init_settings()
	startup_blend_enabled = BlenderImport.blend_import_enabled()
	startup_blender_path = BlenderImport.blender_path()
	log_info("Plugin enabled")
	absolute_download_path = ProjectSettings.globalize_path(download_dir)
	log_info("Download path: %s" % absolute_download_path)
	log_verbose("Client data dir: %s" % ClientBinary.get_client_data_dir())

	connection = ClientConnection.new(self)
	add_child(connection)

	auth = Auth.new()
	auth.plugin = self
	add_child(auth)

	init_gallery()
	ProjectSettings.settings_changed.connect(load_settings)
	EditorInterface.get_editor_settings().settings_changed.connect(load_settings)
	if client_enabled:
		connection.start()


# No unsubscribe here: on editor shutdown the request never reaches the
# Client, as the HTTPRequest is freed with the plugin before it's sent.
func _exit_tree() -> void:
	ProjectSettings.settings_changed.disconnect(load_settings)
	EditorInterface.get_editor_settings().settings_changed.disconnect(load_settings)
	# The children go with the plugin; the gallery lives in the main screen.
	if gallery:
		gallery.queue_free()
		gallery = null
	log_info("Plugin exited")


# Main screen tab. _has_main_screen() is deprecated in Godot 4.8 in favor of an
# EditorDock in DOCK_SLOT_MAIN_SCREEN, but it still works and is the only
# option on Godot 4.0-4.7.
func _has_main_screen() -> bool:
	return true


func _make_visible(visible: bool) -> void:
	if gallery:
		gallery.visible = visible


func _get_plugin_name() -> String:
	return "Blendkit"


# Godot asks again on theme changes, so the icon follows the editor scale and
# light/dark icon colors.
func _get_plugin_icon() -> Texture2D:
	return Icons.render_svg(Icons.ICON_PATH, EditorInterface.get_editor_scale(), true)


func init_gallery() -> void:
	gallery = gallery_scene.instantiate()
	gallery.plugin = self
	gallery.size_flags_vertical = Control.SIZE_EXPAND_FILL
	gallery.hide()
	EditorInterface.get_editor_main_screen().add_child(gallery)


# MARK: settings

func set_client_enabled(enabled: bool) -> void:
	if enabled == client_enabled:
		return
	client_enabled = enabled
	EditorInterface.get_editor_settings().set_setting(SETTING_CLIENT_ENABLED, enabled)
	if enabled:
		connection.start()
	else:
		connection.stop()


func restart_client() -> void:
	set_client_enabled(false)
	set_client_enabled(true)


func set_download_dir(dir: String) -> void:
	if dir == download_dir:
		return
	download_dir = dir
	save_project_setting(SETTING_DOWNLOAD_DIR, download_dir)
	absolute_download_path = ProjectSettings.globalize_path(download_dir)
	log_info("Download path set to: %s" % absolute_download_path)
	download_dir_changed.emit()


func set_log_level(level: int) -> void:
	if level == log_level:
		return
	log_level = level
	EditorInterface.get_editor_settings().set_setting(SETTING_LOG_LEVEL, log_level)
	log_info("Log level set to %s" % LogLevel.keys()[log_level])


func set_preferred_port(new_port: String) -> void:
	if new_port == preferred_port:
		return
	preferred_port = new_port
	EditorInterface.get_editor_settings().set_setting(SETTING_PORT, preferred_port)


func set_model_format(format: String) -> void:
	if format == model_format:
		return
	model_format = format
	save_project_setting(SETTING_MODEL_FORMAT, model_format)
	model_format_changed.emit()


## Godot's switch for .blend import, which applies after a restart.
func set_blend_import_enabled(enabled: bool) -> void:
	if enabled == BlenderImport.blend_import_enabled():
		return
	save_project_setting(BlenderImport.GODOT_ENABLED, enabled)
	log_info(".blend import %s" % ("enabled" if enabled else "disabled"))


func set_blender_path(path: String) -> void:
	if path == BlenderImport.blender_path():
		return
	EditorInterface.get_editor_settings().set_setting(BlenderImport.GODOT_BLENDER_PATH, path)
	log_info("Blender path set to %s" % path if path else "Blender path cleared")


## Whether .blend import [param enabled] with Blender at [param path] differs
## from what Godot set up when the editor started.
func blend_import_needs_restart(enabled: bool, path: String) -> bool:
	return enabled != startup_blend_enabled or (enabled and path != startup_blender_path)


## The resolution to download, with Auto resolved.
func download_resolution() -> String:
	return AUTO_RESOLUTION if resolution.is_empty() else resolution


func set_uuid_names(new_uuid_names: String) -> void:
	if new_uuid_names == uuid_names:
		return
	uuid_names = new_uuid_names
	save_project_setting(SETTING_UUID_NAMES, uuid_names)


func set_resolution(new_resolution: String) -> void:
	if new_resolution == resolution:
		return
	resolution = new_resolution
	save_project_setting(SETTING_RESOLUTION, RESOLUTION_AUTO if resolution.is_empty() else resolution)


## Registers the settings with Godot and reads them, without side effects
## so it can run before the plugin is set up.
func init_settings() -> void:
	add_project_setting(SETTING_DOWNLOAD_DIR, download_dir, PROPERTY_HINT_DIR)
	add_project_setting(SETTING_MODEL_FORMAT, model_format, PROPERTY_HINT_ENUM,
		",".join(MODEL_FORMATS.map(func(f): return f[0])))
	add_project_setting(SETTING_RESOLUTION, RESOLUTION_AUTO, PROPERTY_HINT_ENUM,
		",".join(RESOLUTIONS.map(func(r): return r[0] if r[0] else RESOLUTION_AUTO)))
	add_project_setting(SETTING_UUID_NAMES, uuid_names, PROPERTY_HINT_ENUM, ",".join(UUID_NAMES.map(func(n): return n[0])))
	add_editor_setting(SETTING_CLIENT_ENABLED, client_enabled)
	add_editor_setting(SETTING_PORT, preferred_port, PROPERTY_HINT_ENUM, ",".join(ClientConnection.CLIENT_PORTS))
	add_editor_setting(SETTING_LOG_LEVEL, log_level, PROPERTY_HINT_ENUM, ",".join(LogLevel.keys()))
	# After registering, so migrated defaults aren't written to project.godot.
	for old in OLD_SETTINGS:
		if ProjectSettings.has_setting(old):
			var value = ProjectSettings.get_setting(old)
			var key: String = OLD_SETTINGS[old]
			if key == SETTING_RESOLUTION and str(value).is_empty():
				value = RESOLUTION_AUTO
			if not str(value).is_empty():
				ProjectSettings.set_setting(key, value)
			ProjectSettings.set_setting(old, null)
			ProjectSettings.save()

	var editor_settings := EditorInterface.get_editor_settings()
	download_dir = ProjectSettings.get_setting(SETTING_DOWNLOAD_DIR)
	model_format = ProjectSettings.get_setting(SETTING_MODEL_FORMAT)
	resolution = _resolution_setting()
	uuid_names = ProjectSettings.get_setting(SETTING_UUID_NAMES)
	client_enabled = editor_settings.get_setting(SETTING_CLIENT_ENABLED)
	preferred_port = editor_settings.get_setting(SETTING_PORT)
	log_level = editor_settings.get_setting(SETTING_LOG_LEVEL)


## Applies settings changed elsewhere, e.g. in Godot's settings dialogs.
func load_settings() -> void:
	var editor_settings := EditorInterface.get_editor_settings()
	set_log_level(editor_settings.get_setting(SETTING_LOG_LEVEL))
	set_download_dir(ProjectSettings.get_setting(SETTING_DOWNLOAD_DIR))
	set_model_format(ProjectSettings.get_setting(SETTING_MODEL_FORMAT))
	set_resolution(_resolution_setting())
	set_uuid_names(ProjectSettings.get_setting(SETTING_UUID_NAMES))
	set_preferred_port(editor_settings.get_setting(SETTING_PORT))
	set_client_enabled(editor_settings.get_setting(SETTING_CLIENT_ENABLED))


func _resolution_setting() -> String:
	var value: String = ProjectSettings.get_setting(SETTING_RESOLUTION)
	return "" if value == RESOLUTION_AUTO else value


static func add_project_setting(key: String, default: Variant, hint := PROPERTY_HINT_NONE, hint_string := "") -> void:
	if not ProjectSettings.has_setting(key):
		ProjectSettings.set_setting(key, default)
	ProjectSettings.add_property_info({"name": key, "type": typeof(default), "hint": hint, "hint_string": hint_string})
	# Values equal to the initial one aren't written to project.godot.
	ProjectSettings.set_initial_value(key, default)
	ProjectSettings.set_as_basic(key, true)


static func add_editor_setting(key: String, default: Variant, hint := PROPERTY_HINT_NONE, hint_string := "") -> void:
	var settings := EditorInterface.get_editor_settings()
	if not settings.has_setting(key):
		settings.set_setting(key, default)
	settings.add_property_info({"name": key, "type": typeof(default), "hint": hint, "hint_string": hint_string})
	settings.set_initial_value(key, default, false)


static func save_project_setting(key: String, value: Variant) -> void:
	ProjectSettings.set_setting(key, value)
	ProjectSettings.save()


## Read once, as it's sent with every Client request.
func get_addon_version() -> String:
	if addon_version.is_empty():
		var config := ConfigFile.new()
		var err := config.load("res://addons/blendkit/plugin.cfg")
		addon_version = str(config.get_value("plugin", "version", "unknown")) if err == OK else "unknown"
	return addon_version
