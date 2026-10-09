@tool
extends AcceptDialog
## Settings opened from the Blendkit menu. Changes apply right away. They are
## also in Godot's Project Settings and Editor Settings under Blendkit.

const ClientConnection = preload("res://addons/blendkit/client_connection.gd")
const GalleryApi = preload("res://addons/blendkit/ui/gallery/gallery_api.gd")

var plugin: EditorPlugin

var _grid: GridContainer
var _download_dir: LineEdit
var _download_dir_dialog: EditorFileDialog
var _model_format: OptionButton
var _resolution: OptionButton
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
	_model_format = _options(plugin.MODEL_FORMATS.map(func(f): return f[1]))
	_model_format.item_selected.connect(func(i): plugin.set_model_format(plugin.MODEL_FORMATS[i][0]))
	_row("Model Format", _model_format, "Blender original downloads .blend files, which Godot imports through Blender.\nglTF downloads glTF for Godot, then glTF, and falls back to Blender original at the selected Resolution. glTF files are exported automatically and experimental.")
	_resolution = _options(plugin.RESOLUTIONS.map(func(r): return r[1]))
	_resolution.item_selected.connect(func(i): plugin.set_resolution(plugin.RESOLUTIONS[i][0]))
	_row("Resolution", _resolution, "Texture resolution for .blend files, also used when glTF is unavailable.")

	_section("Editor", "Saved in your editor settings and applies to all your projects.\nAlso in Editor Settings → Blendkit.")
	_port = _options(ClientConnection.CLIENT_PORTS)
	_port.item_selected.connect(func(i): plugin.set_preferred_port(ClientConnection.CLIENT_PORTS[i]))
	_row("Port", _port, "Port on which the plugin starts the Client when none is running.")
	_log_level = _options(plugin.LogLevel.keys())
	_log_level.item_selected.connect(plugin.set_log_level)
	_row("Log Level", _log_level, "Log level for the plugin's output.")

	about_to_popup.connect(_load)
	confirmed.connect(_apply_download_dir)


func _load() -> void:
	_download_dir.text = plugin.download_dir
	_model_format.select(GalleryApi.option_index(plugin.MODEL_FORMATS, plugin.model_format))
	_resolution.select(GalleryApi.option_index(plugin.RESOLUTIONS, plugin.resolution))
	_port.select(maxi(0, ClientConnection.CLIENT_PORTS.find(plugin.preferred_port)))
	_log_level.select(plugin.log_level)


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


func _options(items: Array) -> OptionButton:
	var option := OptionButton.new()
	for item in items:
		option.add_item(str(item))
	return option
