@tool
extends RefCounted
## Shows a downloaded file to the user.

const FilePointer = preload("res://addons/blendkit/ui/file_pointer.gd")
## How long a fresh file may take to show up in the FileSystem dock. The
## editor indexes it only once imported, well after a scan reports it.
const INDEX_WAIT_MS := 30000
## How often to scan again for a file that isn't indexed yet.
const RESCAN_MS := 1000


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


## Let the editor index a new file in the project. A scan asked for while
## another runs is dropped, so it scans again until the file is indexed.
## Returns whether it is, false after [constant INDEX_WAIT_MS].
static func index_file(file_path: String) -> bool:
	var resource_path := ProjectSettings.localize_path(file_path)
	var efs := EditorInterface.get_resource_filesystem()
	var tree := Engine.get_main_loop() as SceneTree
	var deadline := Time.get_ticks_msec() + INDEX_WAIT_MS
	var next_scan := 0
	while not is_indexed(efs, resource_path):
		var now := Time.get_ticks_msec()
		if now > deadline:
			return false
		if now >= next_scan and not efs.is_scanning():
			efs.scan_sources()
			next_scan = now + RESCAN_MS
		await tree.process_frame
	return true


static func is_indexed(efs: EditorFileSystem, resource_path: String) -> bool:
	var dir := efs.get_filesystem_path(resource_path.get_base_dir())
	return dir != null and dir.find_file_index(resource_path.get_file()) >= 0


## Whether the FileSystem dock lists files of this type: ones Godot loads or
## imports (a .blend only with Blender import enabled), and the text and
## other files from the editor settings.
static func is_listed(path: String) -> bool:
	var ext := path.get_extension().to_lower()
	if ext in ResourceLoader.get_recognized_extensions_for_type(""):
		return true
	var settings := EditorInterface.get_editor_settings()
	for key in ["docks/filesystem/textfile_extensions", "docks/filesystem/other_file_extensions"]:
		if ext in str(settings.get_setting(key)).split(",", false):
			return true
	return false


## Whether a downloaded file still waits to show up in the FileSystem dock.
static func is_pending(file_path: String) -> bool:
	var resource_path := ProjectSettings.localize_path(file_path)
	return resource_path.begins_with("res://") and is_listed(resource_path) \
		and not is_indexed(EditorInterface.get_resource_filesystem(), resource_path)
