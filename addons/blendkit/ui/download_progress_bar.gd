@tool
extends ProgressBar

const FileReveal = preload("res://addons/blendkit/ui/file_reveal.gd")
const GalleryApi = preload("res://addons/blendkit/ui/gallery/gallery_api.gd")

enum Status { IDLE, CREATED, PROGRESS, FINISHED, ERROR }

@onready var label : Label = $Label

@export var file_path := ""

var task_id: String = ""
var status: Status = Status.IDLE
var message: String = ""
var cancelled := false
var _revealing := false
var _restyling := false

func _ready() -> void:
	resized.connect(_update_label)
	_update_label()

func _notification(what: int) -> void:
	# Overriding styles below emits THEME_CHANGED again, hence the guard.
	if what == NOTIFICATION_THEME_CHANGED and not _restyling:
		_restyling = true
		_remove_style_overhang()
		_restyling = false


## The editor theme draws progress bars past their rect vertically, which eats
## the container separation and squishes stacked bars together. Keep the
## editor look, but draw within the rect so bars space like other controls.
func _remove_style_overhang() -> void:
	var editor_theme := EditorInterface.get_editor_theme()
	for style_name in ["background", "fill"]:
		var style = editor_theme.get_stylebox(style_name, "ProgressBar").duplicate()
		if style is StyleBoxFlat or style is StyleBoxTexture:
			style.expand_margin_top = 0
			style.expand_margin_bottom = 0
		add_theme_stylebox_override(style_name, style)

func _on_value_changed(_new_value: float) -> void:
	_update_label()

func _gui_input(event: InputEvent) -> void:
	if (
		event is InputEventMouseButton
		and event.button_index == MOUSE_BUTTON_LEFT
		and event.pressed
		and status == Status.FINISHED
		and not file_path.is_empty()
	):
		accept_event()
		if not _revealing:
			_revealing = true
			await FileReveal.reveal(file_path)
			_revealing = false


func _update_label() -> void:
	var clickable := status == Status.FINISHED and not file_path.is_empty()
	mouse_default_cursor_shape = CURSOR_POINTING_HAND if clickable else CURSOR_ARROW
	tooltip_text = "%s\n\nClick to show file." % file_path if clickable else ""

	match status:
		Status.ERROR:
			modulate = Color(1, 0.4, 0.4)
			label.text = message if cancelled else "ERROR: " + message
		Status.FINISHED:
			modulate = Color(1, 1, 1)
			label.text = "DONE " + shorten_path(file_path, get_char_limit() - 5)
		_:
			modulate = Color(1, 1, 1)
			# The client reports only progress and a message (e.g.
			# "Downloading 12.3MB (45%)") until the download finishes.
			label.text = message if not message.is_empty() else "Downloading %d %%" % int(value)


func get_char_limit() -> int:
	return roundi(size.x / 9.0)


static func shorten_path(path: String, max_chars: int) -> String:
	var filename := path.get_file()
	max_chars = maxi(max_chars, 5)
	if filename.length() <= max_chars:
		return filename
	var raw_ext := filename.get_extension()
	var ext := "." + raw_ext if raw_ext != "" else ""
	var base := filename.get_basename() if raw_ext != "" else filename
	var keep := max_chars - ext.length() - 3  # 3 for "..."
	if keep <= 0:
		return filename.left(max_chars)
	return base.left(keep) + "..." + ext


func apply_task(task: Dictionary) -> void:
	task_id = task.get("task_id", task_id)
	status = _parse_status(task.get("status", ""))
	# The Client reports errors in message, too. A cancelled task keeps its
	# last progress message.
	cancelled = task.get("status") == "cancelled"
	message = "Cancelled" if cancelled else str(task.get("message", ""))

	match status:
		Status.ERROR:
			value = 0
		Status.FINISHED:
			value = max_value
			var path := GalleryApi.task_file_path(task)
			if not path.is_empty():
				file_path = path
		_:
			value = task.get("progress", 0)

	_update_label()


static func _parse_status(s: String) -> Status:
	match s:
		"created":  return Status.CREATED
		"progress": return Status.PROGRESS
		"finished": return Status.FINISHED
		"error", "cancelled": return Status.ERROR
		_:          return Status.IDLE
