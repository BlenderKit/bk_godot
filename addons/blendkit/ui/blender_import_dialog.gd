@tool
extends ConfirmationDialog
## Blender Import, opened from Settings: whether Godot imports .blend
## files, and the Blender it imports them with. Godot sets up .blend import
## when the editor starts, so changes apply after a restart.

const BlenderImport = preload("res://addons/blendkit/blender_import.gd")
const Conversions = preload("res://addons/blendkit/conversions.gd")

const WIDTH := 560

enum Choice { DONT_IMPORT, NATIVE }
## [label, description], indexed by Choice.
const CHOICES = [
	["Don't import .blend", "Godot never imports .blend files. Blendkit still downloads them, for converting with your own tools, but they stay hidden in the FileSystem dock. glTF (.glb) downloads import as usual."],
	["Native .blend import", "Godot converts each .blend on this computer with Blender and imports it as a scene. Every computer that opens the project needs Blender %d.0+. Large assets can take long to import, again whenever they change." % BlenderImport.MIN_VERSION],
]
## Shown while .blend import is on, Godot's default, without a working Blender.
const NO_BLENDER = ".blend import is on, but Blender isn't set up on this computer, so .blend files stay hidden. Set up Blender, or choose Don't import .blend."

var plugin: EditorPlugin

var _intro: Label
# Scaled left margin that lines content up with the radio buttons' text
var _indent: int
var _choices: Array[CheckBox] = []
var _descriptions: Array[Label] = []
var _blender_box: Control
var _blender_path: LineEdit
var _blender_icon: TextureRect
var _blender_note: Label
var _browse_button: Button
var _detect: Button
var _detect_menu: PopupMenu
var _detected: Array[Dictionary] = []
var _browse_dialog: EditorFileDialog
var _restart: Button
# Blender versions by path, "" when not Blender; checked on worker threads
var _versions := {}
var _tasks := {}
var _detect_task := -1


## Called by Settings once the plugin is known.
func setup(new_plugin: EditorPlugin) -> void:
	plugin = new_plugin
	title = "Blender Import"
	ok_button_text = "Apply"
	var edscale := EditorInterface.get_editor_scale()
	var box := VBoxContainer.new()
	box.custom_minimum_size.x = WIDTH * edscale
	box.add_theme_constant_override("separation", int(4 * edscale))
	add_child(box)
	# Where CheckBox draws its text: past its margin, radio icon and separation.
	_indent = int(get_theme_stylebox("normal", "CheckBox").get_margin(SIDE_LEFT)) + get_theme_icon("radio_unchecked", "CheckBox").get_width() + get_theme_constant("h_separation", "CheckBox")

	_intro = _wrapped(NO_BLENDER, WIDTH * edscale)
	_intro.add_theme_color_override("font_color", get_theme_color("warning_color", "Editor"))
	box.add_child(_intro)
	var group := ButtonGroup.new()
	for i in CHOICES.size():
		var check := CheckBox.new()
		check.text = CHOICES[i][0]
		check.button_group = group
		check.add_theme_font_override("font", get_theme_font("bold", "EditorFonts"))
		check.toggled.connect(func(_on): _refresh())
		if i > 0:
			check.custom_minimum_size.y = 32 * edscale
			check.size_flags_vertical = Control.SIZE_SHRINK_END
		box.add_child(check)
		_choices.append(check)
		var description := _unpadded(_wrapped(CHOICES[i][1], WIDTH * edscale - _indent))
		box.add_child(_indented(description))
		_descriptions.append(description)
	_blender_box = _indented(_blender_row())
	_blender_box.add_theme_constant_override("margin_top", int(6 * edscale))
	box.add_child(_blender_box)

	_restart = add_button("Apply & Restart", true, "restart")
	_restart.tooltip_text = "Godot sets up .blend import when the editor starts."
	custom_action.connect(func(action):
		if action == "restart":
			hide()
			_apply()
			EditorInterface.restart_editor(true))
	confirmed.connect(_apply)
	about_to_popup.connect(_load)


func _exit_tree() -> void:
	for task in _tasks.values():
		WorkerThreadPool.wait_for_task_completion(task)
	_tasks.clear()
	if _detect_task != -1:
		WorkerThreadPool.wait_for_task_completion(_detect_task)
		_detect_task = -1


## Indented to the text of the radio buttons above.
func _indented(control: Control) -> MarginContainer:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", _indent)
	margin.add_child(control)
	return margin


## Path, browse and detect, like EditorPropertyPath, and whether it's usable.
func _blender_row() -> Control:
	var edscale := EditorInterface.get_editor_scale()
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", int(4 * edscale))
	var row := HBoxContainer.new()
	box.add_child(row)
	var label := _unpadded(Label.new())
	label.text = "Blender Path"
	# Space before the path, which the HBox separation alone crowds.
	label.get_theme_stylebox("normal").content_margin_right = 6 * edscale
	label.tooltip_text = "Blender that Godot imports .blend files with, on this computer, for all projects.\nEditor Settings › " + BlenderImport.GODOT_BLENDER_PATH
	label.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(label)
	_blender_path = LineEdit.new()
	_blender_path.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_blender_path.placeholder_text = "Path to the Blender executable"
	_blender_path.tooltip_text = label.tooltip_text
	_blender_path.text_changed.connect(func(_t): _refresh())
	row.add_child(_blender_path)
	_browse_button = Button.new()
	_browse_button.icon = get_theme_icon("FolderBrowse", "EditorIcons")
	_browse_button.theme_type_variation = "EditorInspectorButton"
	_browse_button.tooltip_text = "Choose the Blender executable."
	_browse_button.pressed.connect(_browse)
	row.add_child(_browse_button)
	_detect = Button.new()
	_detect.text = "Detect"
	_detect.icon = get_theme_icon("Search", "EditorIcons")
	_detect.tooltip_text = "Look for Blender %d.0+ where it's usually installed." % BlenderImport.MIN_VERSION
	_detect.pressed.connect(_start_detect)
	row.add_child(_detect)

	var note := HBoxContainer.new()
	_blender_icon = TextureRect.new()
	_blender_icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	note.add_child(_blender_icon)
	_blender_note = Label.new()
	note.add_child(_blender_note)
	box.add_child(note)

	_detect_menu = PopupMenu.new()
	_detect_menu.id_pressed.connect(func(i): _set_path(_detected[i].path))
	add_child(_detect_menu)
	_browse_dialog = EditorFileDialog.new()
	_browse_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_ANY if OS.get_name() == "macOS" else EditorFileDialog.FILE_MODE_OPEN_FILE
	_browse_dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
	_browse_dialog.file_selected.connect(_on_browsed)
	_browse_dialog.dir_selected.connect(_on_browsed)
	add_child(_browse_dialog)
	return box


## Wraps [param text] at [param width] pixels, which a wrapped label needs
## as its minimum width.
func _wrapped(text: String, width: float) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size.x = width
	return label


## Without the editor's Label margins, so the text lines up with the
## radio button text and sits right below it.
func _unpadded(label: Label) -> Label:
	label.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	return label


func _selected() -> Choice:
	return Choice.NATIVE if _choices[Choice.NATIVE].button_pressed else Choice.DONT_IMPORT


func _load() -> void:
	var current := Choice.NATIVE if BlenderImport.blend_import_enabled() else Choice.DONT_IMPORT
	for i in _choices.size():
		_choices[i].set_pressed_no_signal(i == current)
	_blender_path.text = BlenderImport.blender_path()
	# Check again, Blender may have been installed or removed since.
	_versions.clear()
	_refresh()
	reset_size.call_deferred()


func _apply() -> void:
	var native := _selected() == Choice.NATIVE
	if native:
		plugin.set_blender_path(_blender_path.text.strip_edges())
	plugin.set_blend_import_enabled(native)
	Conversions.forget_detected()


func _refresh() -> void:
	var native := _selected() == Choice.NATIVE
	var path := _blender_path.text.strip_edges()
	var version := _version(path)
	var ok := BlenderImport.is_supported(version)
	# Blender only matters for Native import.
	_blender_box.modulate.a = 1.0 if native else 0.5
	_blender_path.editable = native
	_browse_button.disabled = not native
	_detect.disabled = not native or _detect_task != -1
	# Dim the descriptions of unselected choices.
	for i in _descriptions.size():
		if _choices[i].button_pressed:
			_descriptions[i].remove_theme_color_override("font_color")
		else:
			_descriptions[i].add_theme_color_override("font_color", get_theme_color("font_placeholder_color", "Editor"))

	var icon := "StatusSuccess" if ok else "StatusError"
	var color := get_theme_color("success_color", "Editor") if ok else get_theme_color("error_color", "Editor")
	if version == null:
		icon = "Timer"
		color = get_theme_color("font_color", "Editor")
	_blender_icon.texture = get_theme_icon(icon, "EditorIcons")
	_blender_note.text = _version_text(path, version)
	_blender_note.add_theme_color_override("font_color", color)

	# Warn while .blend import is on without a working Blender, unless the
	# choices made here fix it.
	var applied: Variant = _version(BlenderImport.blender_path())
	var broken := BlenderImport.blend_import_enabled() and applied != null and not BlenderImport.is_supported(applied)
	var intro_visible := broken and native and not ok
	if intro_visible != _intro.visible:
		_intro.visible = intro_visible
		reset_size.call_deferred()

	var apply := get_ok_button()
	apply.disabled = native and not ok
	apply.tooltip_text = "Native import needs Blender %d.0+." % BlenderImport.MIN_VERSION if apply.disabled else ""
	_restart.visible = plugin.blend_import_needs_restart(native, path) and not apply.disabled
	apply.text = "Apply Without Restart" if _restart.visible else "Apply"


# MARK: Blender

## The cached version at [param path], null while it's checked. Starts the
## check on a worker thread, as Blender takes a moment to start.
func _version(path: String) -> Variant:
	if path.is_empty():
		return ""
	if _versions.has(path):
		return _versions[path]
	if not _tasks.has(path):
		_tasks[path] = WorkerThreadPool.add_task(func():
			_on_version.call_deferred(path, BlenderImport.blender_version(path)))
	return null


func _on_version(path: String, version: String) -> void:
	WorkerThreadPool.wait_for_task_completion(_tasks[path])
	_tasks.erase(path)
	_versions[path] = version
	_refresh()


func _version_text(path: String, version: Variant) -> String:
	if path.is_empty():
		return "Not set. Detect Blender or browse for it."
	if version == null:
		return "Checking…"
	if version.is_empty() and not FileAccess.file_exists(path):
		return "File not found."
	if version.is_empty():
		return "Not Blender, or it didn't start."
	if not BlenderImport.is_supported(version):
		return "Blender %s is too old, Godot needs %d.0+." % [version, BlenderImport.MIN_VERSION]
	return "Blender %s" % version


func _set_path(path: String) -> void:
	_blender_path.text = path
	_refresh()


func _browse() -> void:
	var path := _blender_path.text.strip_edges()
	if not path.is_empty():
		_browse_dialog.current_path = path
	_browse_dialog.popup_file_dialog()


## A picked macOS app bundle means the executable inside.
func _on_browsed(path: String) -> void:
	if path.ends_with(".app"):
		path = path.path_join("Contents/MacOS/Blender")
	_set_path(path)


func _start_detect() -> void:
	if _detect_task != -1:
		return
	_detect.text = "Detecting…"
	_detect_task = WorkerThreadPool.add_task(func():
		_on_detected.call_deferred(BlenderImport.detect()))
	_refresh()


## One install fills the path, several open a menu to pick from.
func _on_detected(found: Array[Dictionary]) -> void:
	WorkerThreadPool.wait_for_task_completion(_detect_task)
	_detect_task = -1
	_detect.text = "Detect"
	for install in found:
		_versions[install.path] = install.version
	_detected = found
	_refresh()
	if found.is_empty():
		_blender_note.text = "No Blender %d.0+ found. Install it from blender.org, or browse for it." % BlenderImport.MIN_VERSION
		return
	if found.size() == 1:
		_set_path(found[0].path)
		return
	_detect_menu.clear()
	for i in found.size():
		_detect_menu.add_item("Blender %s · %s" % [found[i].version, found[i].path], i)
	_detect_menu.reset_size()
	var pos := _detect.get_screen_position() + Vector2(0, _detect.size.y)
	_detect_menu.popup(Rect2i(Vector2i(pos), Vector2i.ZERO))
