@tool
extends ProgressBar

enum Status { IDLE, CREATED, PROGRESS, FINISHED, ERROR }

@onready var label : Label = $Label

@export var file_path := ""

var task_id: String = ""
var status: Status = Status.IDLE
var message: String = ""
var _revealing := false

func _ready() -> void:
	resized.connect(_update_label)
	_update_label()

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
			await _reveal_file()
			_revealing = false


## Select the file in the FileSystem dock, or show it in the OS file manager
## when it's outside the project or of a type the dock doesn't list.
func _reveal_file() -> void:
	var resource_path := ProjectSettings.localize_path(file_path)
	if resource_path.begins_with("res://"):
		var efs := EditorInterface.get_resource_filesystem()
		if not _is_indexed(efs, resource_path):
			# Freshly downloaded files may not be scanned yet.
			efs.scan_sources()
			await efs.sources_changed
		if _is_indexed(efs, resource_path):
			EditorInterface.get_file_system_dock().navigate_to_path(resource_path)
			return
	OS.shell_show_in_file_manager(ProjectSettings.globalize_path(file_path))


static func _is_indexed(efs: EditorFileSystem, resource_path: String) -> bool:
	var dir := efs.get_filesystem_path(resource_path.get_base_dir())
	return dir != null and dir.find_file_index(resource_path.get_file()) >= 0


func _update_label() -> void:
	var clickable := status == Status.FINISHED and not file_path.is_empty()
	mouse_default_cursor_shape = CURSOR_POINTING_HAND if clickable else CURSOR_ARROW
	tooltip_text = "%s\n\nClick to show file." % file_path if clickable else ""

	match status:
		Status.ERROR:
			modulate = Color(1, 0.4, 0.4)
			label.text = "ERROR: " + message
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
	message = task.get("error" if status == Status.ERROR else "message", "")

	match status:
		Status.ERROR:
			value = 0
		Status.FINISHED:
			value = max_value
			var result = task.get("result", {})
			if result is Dictionary and result.has("file_path"):
				file_path = result["file_path"]
		_:
			value = task.get("progress", 0)

	_update_label()


static func _parse_status(s: String) -> Status:
	match s:
		"created":  return Status.CREATED
		"progress": return Status.PROGRESS
		"finished": return Status.FINISHED
		"error":    return Status.ERROR
		_:          return Status.IDLE
