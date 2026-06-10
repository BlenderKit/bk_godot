@tool
extends ProgressBar

enum Status { IDLE, CREATED, PROGRESS, FINISHED, ERROR }
const COPY_FEEDBACK_TEXT := "Path copied to clipboard 📋"
const COPY_FEEDBACK_DURATION_SEC := 1.0

@onready var label : Label = $Label

@export var file_path := '/path/to/file_name.blend'

var task_id: String = ""
var status: Status = Status.IDLE
var message: String = ""
var _copy_feedback_count: int = 0

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
		and not file_path.is_empty()
		and DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD)
	):
		DisplayServer.clipboard_set(file_path)
		_show_copy_feedback()
		accept_event()

func _update_label() -> void:
	var next_text := ""
	match status:
		Status.ERROR:
			modulate = Color(1, 0.4, 0.4)
			next_text = "ERROR: " + message
		Status.FINISHED:
			modulate = Color(1, 1, 1)
			next_text = "DONE " + shorten_path(file_path, get_char_limit() - 5)
		_:
			modulate = Color(1, 1, 1)
			var prefix := "%d %% " % int(value)
			next_text = prefix + shorten_path(file_path, get_char_limit() - prefix.length())

	label.text = COPY_FEEDBACK_TEXT if _is_copy_feedback_active() else next_text


func _show_copy_feedback() -> void:
	_copy_feedback_count += 1
	_update_label()
	get_tree().create_timer(COPY_FEEDBACK_DURATION_SEC).timeout.connect(_end_copy_feedback)


func _end_copy_feedback() -> void:
	_copy_feedback_count -= 1
	_update_label()


func _is_copy_feedback_active() -> bool:
	return _copy_feedback_count > 0


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
