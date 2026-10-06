@tool
extends RefCounted
## Shows a downloaded file to the user.


## Select the file in the FileSystem dock, or show it in the OS file manager
## when it's outside the project or of a type the dock doesn't list.
static func reveal(file_path: String) -> void:
	var resource_path := ProjectSettings.localize_path(file_path)
	if resource_path.begins_with("res://"):
		var efs := EditorInterface.get_resource_filesystem()
		if not is_indexed(efs, resource_path):
			# Freshly downloaded files may not be scanned yet.
			efs.scan_sources()
			await efs.sources_changed
		if is_indexed(efs, resource_path):
			EditorInterface.get_file_system_dock().navigate_to_path(resource_path)
			return
	OS.shell_show_in_file_manager(ProjectSettings.globalize_path(file_path))


static func is_indexed(efs: EditorFileSystem, resource_path: String) -> bool:
	var dir := efs.get_filesystem_path(resource_path.get_base_dir())
	return dir != null and dir.find_file_index(resource_path.get_file()) >= 0
