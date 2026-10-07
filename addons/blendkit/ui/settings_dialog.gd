@tool
extends AcceptDialog
## Settings opened from the Blendkit menu. Changes apply right away.

var plugin: EditorPlugin

var _grid: GridContainer
var _download_dir: LineEdit
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

	_section("Downloads")
	_download_dir = LineEdit.new()
	_download_dir.text_submitted.connect(func(_t): _apply_download_dir())
	_download_dir.focus_exited.connect(_apply_download_dir)
	_row("Download to", _download_dir, "Directory into which the plugin downloads the assets.")
	_model_format = _options(plugin.MODEL_FORMATS.map(func(f): return f[1]))
	_model_format.item_selected.connect(func(i): plugin.set_model_format(plugin.MODEL_FORMATS[i][0]))
	_row("Model Format", _model_format, "Choose whether to download GLTF files (recommended for Godot) or original .blend files.")
	_resolution = _options(plugin.RESOLUTIONS.map(func(r): return r[1]))
	_resolution.item_selected.connect(func(i): plugin.set_resolution(plugin.RESOLUTIONS[i][0]))
	_row("Resolution", _resolution, "Resolution for .blend files. Also used as fallback when GLTF is unavailable.")

	_section("Client")
	_port = _options(plugin.CLIENT_PORTS)
	_port.item_selected.connect(func(i): plugin.preferred_port = plugin.CLIENT_PORTS[i])
	_row("Port", _port, "Port on which the plugin starts the Client when none is running.")
	_log_level = _options(plugin.LOG_LEVEL_NAMES.values())
	_log_level.item_selected.connect(plugin.set_log_level)
	_row("Log Level", _log_level, "Log level for the plugin's output.")

	about_to_popup.connect(_load)
	confirmed.connect(_apply_download_dir)


func _load() -> void:
	_download_dir.text = plugin.download_dir
	_model_format.select(maxi(0, plugin.MODEL_FORMATS.map(func(f): return f[0]).find(plugin.model_format)))
	_resolution.select(maxi(0, plugin.RESOLUTIONS.map(func(r): return r[0]).find(plugin.resolution)))
	_port.select(maxi(0, plugin.CLIENT_PORTS.find(plugin.preferred_port)))
	_log_level.select(plugin.log_level)


func _apply_download_dir() -> void:
	plugin.set_download_dir(_download_dir.text.strip_edges())


func _section(text: String) -> void:
	var edscale := EditorInterface.get_editor_scale()
	for i in 2:
		var label := Label.new()
		if i == 0:
			label.text = text
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
