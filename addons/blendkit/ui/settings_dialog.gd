@tool
extends AcceptDialog
## Settings opened from the Blendkit menu. Changes apply right away. They are
## also in Godot's Project Settings and Editor Settings under Blendkit.

const BlenderImport = preload("res://addons/blendkit/blender_import.gd")
const BlenderImportDialog = preload("res://addons/blendkit/ui/blender_import_dialog.gd")
const ClientConnection = preload("res://addons/blendkit/client_connection.gd")
const GalleryApi = preload("res://addons/blendkit/ui/gallery/gallery_api.gd")

var plugin: EditorPlugin

var _grid: GridContainer
var _download_dir: LineEdit
var _download_dir_dialog: EditorFileDialog
var _model_format: OptionButton
var _blend_import: Button
# Opened from the Blender Import row, back to Settings after Apply or Cancel.
var _blender_import_dialog: BlenderImportDialog
var _resolution: OptionButton
var _uuid_names: OptionButton
var _port: OptionButton
var _log_level: OptionButton


## Called by the menu once the plugin is known.
func setup(new_plugin: EditorPlugin) -> void:
	plugin = new_plugin
	title = "Blendkit Settings"
	ok_button_text = "Close"
	var edscale := EditorInterface.get_editor_scale()
	_grid = GridContainer.new()
	_grid.columns = 2
	_grid.add_theme_constant_override("h_separation", int(12 * edscale))
	_grid.add_theme_constant_override("v_separation", int(6 * edscale))
	add_child(_grid)

	_section("Project", "Saved in project.godot and shared with everyone working on this project.\nAlso in Project Settings → Blendkit.")
	_download_dir = LineEdit.new()
	_download_dir.text_submitted.connect(func(_t): _apply_download_dir())
	_download_dir.focus_exited.connect(_apply_download_dir)
	_download_dir.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Like EditorPropertyPath in Project Settings: path and a browse button.
	var browse := Button.new()
	browse.icon = get_theme_icon("FolderBrowse", "EditorIcons")
	# Godot 4.6+, older versions fall back to the plain Button style.
	browse.theme_type_variation = "EditorInspectorButton"
	browse.tooltip_text = "Choose the download folder."
	browse.pressed.connect(_browse_download_dir)
	var download_row := HBoxContainer.new()
	download_row.add_child(_download_dir)
	download_row.add_child(browse)
	_download_dir_dialog = EditorFileDialog.new()
	_download_dir_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_DIR
	_download_dir_dialog.access = EditorFileDialog.ACCESS_RESOURCES
	_download_dir_dialog.dir_selected.connect(_on_download_dir_selected)
	add_child(_download_dir_dialog)
	_row("Download to", download_row, "Directory into which the plugin downloads the assets.")
	_download_dir.tooltip_text = download_row.tooltip_text
	_blend_import = _dialog_button()
	_blend_import.pressed.connect(func():
		hide()
		_blender_import_dialog.popup_centered())
	_row("Blender Import", _blend_import, "Whether Godot imports .blend files, and the Blender it imports them with.\nClick to change them.")
	_model_format = _options(plugin.MODEL_FORMATS.map(func(f): return f[1]))
	_model_format.item_selected.connect(func(i): plugin.set_model_format(plugin.MODEL_FORMATS[i][0]))
	_row("Model Format", _model_format, "Blender (.blend) downloads .blend files at the selected Resolution, which Godot imports only through Blender.\nglTF (.glb) downloads .glb files exported by Blendkit, which Godot imports directly. Only some models have one, so the Blendkit tab shows only those, and other models fall back to .blend at the selected Resolution. Experimental.")
	_resolution = _options(plugin.RESOLUTIONS.map(func(r): return r[1]))
	_resolution.item_selected.connect(func(i): plugin.set_resolution(plugin.RESOLUTIONS[i][0]))
	_row("Resolution", _resolution, "Texture resolution for .blend files, also used when glTF is unavailable. Auto downloads 2K.")
	_uuid_names = _options(plugin.UUID_NAMES.map(func(n): return n[1]))
	_uuid_names.item_selected.connect(func(i): plugin.set_uuid_names(plugin.UUID_NAMES[i][0]))
	_row("UUIDs in Names", _uuid_names, "How downloaded folders and files are named, for new downloads.\nFull: with the whole asset and file UUIDs, like chair_1a2b3c4d-…/chair_gltf_godot_5e6f7a8b-….glb.\nShort: with their first 8 characters, like chair_1a2b3c4d/chair_gltf_godot_5e6f7a8b.glb.\nStrip: without them, like chair/chair_gltf_godot.glb. Assets with the same name get a short UUID. A newer version of an asset replaces the older one in its folder.")

	_section("Editor", "Saved in your editor settings and applies to all your projects.\nAlso in Editor Settings → Blendkit.")
	_port = _options(ClientConnection.CLIENT_PORTS)
	_port.item_selected.connect(func(i): plugin.set_preferred_port(ClientConnection.CLIENT_PORTS[i]))
	_row("Port", _port, "Port on which the plugin starts the Client when none is running.")
	_log_level = _options(plugin.LogLevel.keys())
	_log_level.item_selected.connect(plugin.set_log_level)
	_row("Log Level", _log_level, "Log level for the plugin's output.")

	# A sibling, as a child window would hide with Settings.
	_blender_import_dialog = BlenderImportDialog.new()
	get_parent().add_child(_blender_import_dialog)
	_blender_import_dialog.setup(plugin)
	# Deferred, as Cancel hides the dialog deferred too.
	_blender_import_dialog.confirmed.connect(popup_centered, CONNECT_DEFERRED)
	_blender_import_dialog.canceled.connect(popup_centered, CONNECT_DEFERRED)

	about_to_popup.connect(_load)
	confirmed.connect(_apply_download_dir)


func _load() -> void:
	_download_dir.text = plugin.download_dir
	_load_blend_import()
	_model_format.select(GalleryApi.option_index(plugin.MODEL_FORMATS, plugin.model_format))
	_resolution.select(GalleryApi.option_index(plugin.RESOLUTIONS, plugin.resolution))
	_uuid_names.select(GalleryApi.option_index(plugin.UUID_NAMES, plugin.uuid_names))
	_port.select(maxi(0, ClientConnection.CLIENT_PORTS.find(plugin.preferred_port)))
	_log_level.select(plugin.log_level)


## Like the Blender Import choices, warning while .blend import is on without
## Blender. Only checks that the file is there, as running Blender is slow.
func _load_blend_import() -> void:
	var path := BlenderImport.blender_path()
	var native := BlenderImport.blend_import_enabled()
	var missing := native and (path.is_empty() or not FileAccess.file_exists(path))
	if not native:
		_blend_import.text = BlenderImportDialog.CHOICES[BlenderImportDialog.Choice.DONT_IMPORT][0]
	elif missing:
		_blend_import.text = "Blender isn't set up"
	else:
		_blend_import.text = BlenderImportDialog.CHOICES[BlenderImportDialog.Choice.NATIVE][0]
	if plugin.blend_import_needs_restart(native, path):
		_blend_import.text += " (after restart)"
	for color in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		if missing:
			_blend_import.add_theme_color_override(color, get_theme_color("warning_color", "Editor"))
		else:
			_blend_import.remove_theme_color_override(color)


func _browse_download_dir() -> void:
	_download_dir_dialog.current_dir = _download_dir.text.strip_edges()
	_download_dir_dialog.popup_file_dialog()


func _on_download_dir_selected(dir: String) -> void:
	_download_dir.text = dir
	_apply_download_dir()


func _apply_download_dir() -> void:
	plugin.set_download_dir(_download_dir.text.strip_edges())


func _section(text: String, tooltip: String) -> void:
	var edscale := EditorInterface.get_editor_scale()
	for i in 2:
		var label := Label.new()
		if i == 0:
			label.text = text
			label.tooltip_text = tooltip
			label.mouse_filter = Control.MOUSE_FILTER_PASS
			label.add_theme_font_override("font", get_theme_font("bold", "EditorFonts"))
		if _grid.get_child_count() > 0:
			label.custom_minimum_size.y = 24 * edscale
			label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		_grid.add_child(label)


func _row(text: String, control: Control, tooltip: String) -> void:
	var label := Label.new()
	label.text = text
	label.tooltip_text = tooltip
	label.mouse_filter = Control.MOUSE_FILTER_PASS
	control.tooltip_text = tooltip
	control.custom_minimum_size.x = 220 * EditorInterface.get_editor_scale()
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_child(label)
	_grid.add_child(control)


## Looks like an OptionButton, with vertical dots for its arrow: shows a value
## and opens a dialog to change it.
func _dialog_button() -> Button:
	var button := Button.new()
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	button.clip_text = true
	button.icon = get_theme_icon("GuiTabMenuHl", "EditorIcons")
	button.icon_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	return button


func _options(items: Array) -> OptionButton:
	var option := OptionButton.new()
	for item in items:
		option.add_item(str(item))
	return option
