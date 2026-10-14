@tool
extends RefCounted
## Shows a downloaded file to the user.

const FilePointer = preload("res://addons/blendkit/ui/file_pointer.gd")
## How long a fresh file may take to show up in the FileSystem dock. The
## editor indexes it only once imported, well after a scan reports it.
const INDEX_WAIT_MS := 30000
## How often to scan again for a file that isn't indexed yet.
const RESCAN_MS := 1000

## Extensions of the files the FileSystem dock lists, see is_listed(), {}
## once the editor settings changed.
static var _listed: Dictionary = {}
static var _watching_settings := false
## Files changed since the last scan started, so another one is due.
static var _rescan_wanted := false
## res:// path -> msec deadline of the files waiting to be indexed.
static var _awaited: Dictionary = {}
static var _scanning := false
## Emitted after each round of _scan(), see index_file().
static var _rounds := Rounds.new()


## Select the file in the FileSystem dock, or show it in the OS file manager
## when it's outside the project or of a type the dock doesn't list.
static func reveal(file_path: String) -> void:
	var resource_path := ProjectSettings.localize_path(file_path)
	if resource_path.begins_with("res://") and is_listed(resource_path):
		# Freshly downloaded files may not be indexed yet.
		if await index_file(file_path):
			EditorInterface.get_file_system_dock().navigate_to_path(resource_path)
			FilePointer.point_at(resource_path)
			return
	OS.shell_show_in_file_manager(ProjectSettings.globalize_path(file_path))


## Let the editor index a new file in the project. Returns whether it is,
## false after [constant INDEX_WAIT_MS].
static func index_file(file_path: String) -> bool:
	var resource_path := ProjectSettings.localize_path(file_path)
	var efs := EditorInterface.get_resource_filesystem()
	if is_indexed(efs, resource_path):
		return true
	_await_index(resource_path)
	_scan()
	while _awaited.has(resource_path):
		await _rounds.done
	return is_indexed(efs, resource_path)


## Let the editor import a downloaded file in the project, also one it
## imported before and the files that moved along. It checks the files it
## knows for changes only on a scan, so files that change meanwhile share
## the next one. Then a new file is indexed, see index_file().
static func rescan(file_path: String) -> void:
	var resource_path := ProjectSettings.localize_path(file_path)
	_rescan_wanted = true
	if is_listed(resource_path):
		_await_index(resource_path)
	_scan()


static func _await_index(resource_path: String) -> void:
	if not _awaited.has(resource_path):
		_awaited[resource_path] = Time.get_ticks_msec() + INDEX_WAIT_MS


## Scan while a scan is wanted or a file waits to be indexed. A scan asked
## for while another runs is dropped, so each starts once the editor's
## ended, and again every [constant RESCAN_MS] until the files are indexed.
## It waits for scans to end rather than checking each frame.
static func _scan() -> void:
	if _scanning:
		return
	_scanning = true
	var efs := EditorInterface.get_resource_filesystem()
	var next_scan := 0
	while true:
		var now := Time.get_ticks_msec()
		for path in _awaited.keys():
			if is_indexed(efs, path) or now > _awaited[path]:
				_awaited.erase(path)
		_rounds.done.emit()
		if not _rescan_wanted and _awaited.is_empty():
			break
		if not efs.is_scanning() and now >= next_scan:
			_rescan_wanted = false
			next_scan = now + RESCAN_MS
			efs.scan_sources()
		await _scan_end(efs, RESCAN_MS / 1000.0)
	_scanning = false


## Wait for the editor's scan to end, or [param seconds] at most.
static func _scan_end(efs: EditorFileSystem, seconds: float) -> void:
	var waiter := Waiter.new()
	efs.sources_changed.connect(waiter.scanned)
	(Engine.get_main_loop() as SceneTree).create_timer(seconds).timeout.connect(waiter.done)
	await waiter.finished
	efs.sources_changed.disconnect(waiter.scanned)


static func is_indexed(efs: EditorFileSystem, resource_path: String) -> bool:
	var dir := efs.get_filesystem_path(resource_path.get_base_dir())
	return dir != null and dir.find_file_index(resource_path.get_file()) >= 0


## Whether the FileSystem dock lists files of this type: ones Godot loads or
## imports (a .blend only with Blender import enabled), and the text and
## other files from the editor settings.
static func is_listed(path: String) -> bool:
	if _listed.is_empty():
		_listed = _listed_extensions()
	return _listed.has(path.get_extension().to_lower())


static func _listed_extensions() -> Dictionary:
	var result := {}
	for ext in ResourceLoader.get_recognized_extensions_for_type(""):
		result[ext.to_lower()] = true
	var settings := EditorInterface.get_editor_settings()
	for key in ["docks/filesystem/textfile_extensions", "docks/filesystem/other_file_extensions"]:
		for ext in str(settings.get_setting(key)).split(",", false):
			result[ext.strip_edges().to_lower()] = true
	if not _watching_settings:
		_watching_settings = true
		settings.settings_changed.connect(func(): _listed = {})
	return result


## Whether a downloaded file still waits to show up in the FileSystem dock.
static func is_pending(file_path: String) -> bool:
	var resource_path := ProjectSettings.localize_path(file_path)
	return resource_path.begins_with("res://") and is_listed(resource_path) \
		and not is_indexed(EditorInterface.get_resource_filesystem(), resource_path)


class Rounds:
	signal done


## Ends with the editor's scan or the timer, whichever comes first.
class Waiter:
	signal finished
	var _done := false

	func scanned(_changed: bool) -> void:
		done()

	func done() -> void:
		if not _done:
			_done = true
			finished.emit()
