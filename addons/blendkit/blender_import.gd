@tool
extends RefCounted
## How Godot imports .blend files: Godot's settings behind it and finding
## Blender on this computer. The Blender Import dialog shows and changes it.

## Godot imports .blend files only with this on (project setting, shared).
const GODOT_ENABLED = "filesystem/import/blender/enabled"
## Blender that Godot runs to import .blend files (editor setting, this
## computer, all projects).
const GODOT_BLENDER_PATH = "filesystem/import/blender/blender_path"
## Godot's .blend import needs at least this Blender.
const MIN_VERSION = 3

static func blend_import_enabled() -> bool:
	return ProjectSettings.get_setting(GODOT_ENABLED, true)


static func blender_path() -> String:
	return str(EditorInterface.get_editor_settings().get_setting(GODOT_BLENDER_PATH))


## The Blender version string at [param path], e.g. "4.5.1", or "" when it
## isn't Blender. Runs Blender, so call it from a thread.
static func blender_version(path: String) -> String:
	if path.is_empty() or not FileAccess.file_exists(path):
		return ""
	var output := []
	if OS.execute(path, ["--version"], output, true) != 0 or output.is_empty():
		return ""
	return parse_version(str(output[0]))


## "4.5.1" from Blender's --version output, "" when it isn't there.
static func parse_version(output: String) -> String:
	var regex := RegEx.create_from_string("(?m)^Blender (\\d+\\.\\d+(?:\\.\\d+)?)")
	var m := regex.search(output)
	return m.get_string(1) if m else ""


## Whether Godot can import with this Blender version, false for null while
## it's checked.
static func is_supported(version: Variant) -> bool:
	return version is String and not version.is_empty() and version.split(".")[0].to_int() >= MIN_VERSION


## Newest first.
static func compare_versions(a: String, b: String) -> bool:
	var pa := a.split(".")
	var pb := b.split(".")
	for i in maxi(pa.size(), pb.size()):
		var na := pa[i].to_int() if i < pa.size() else 0
		var nb := pb[i].to_int() if i < pb.size() else 0
		if na != nb:
			return na > nb
	return false


## Where Blender usually is on this OS, existing files only. Like Godot's own
## auto-detect, plus PATH, Steam, Snap and Flatpak.
static func candidate_paths() -> PackedStringArray:
	var windows := OS.get_name() == "Windows"
	var exe := "blender.exe" if windows else "blender"
	var paths := PackedStringArray()
	for dir in OS.get_environment("PATH").split(";" if windows else ":", false):
		paths.append(dir.path_join(exe))
	match OS.get_name():
		"Windows":
			for env in ["ProgramFiles", "ProgramW6432", "ProgramFiles(x86)"]:
				var root := OS.get_environment(env)
				if root.is_empty():
					continue
				var foundation := root.path_join("Blender Foundation")
				for dir in DirAccess.get_directories_at(foundation):
					paths.append(foundation.path_join(dir).path_join(exe))
				paths.append(root.path_join("Steam/steamapps/common/Blender").path_join(exe))
		"macOS":
			for apps in ["/Applications", OS.get_environment("HOME").path_join("Applications")]:
				for dir in DirAccess.get_directories_at(apps):
					if dir.begins_with("Blender") and dir.ends_with(".app"):
						paths.append(apps.path_join(dir).path_join("Contents/MacOS/Blender"))
		_:
			var home := OS.get_environment("HOME")
			for dir in ["/usr/bin", "/usr/local/bin", home.path_join(".local/bin"), "/snap/bin"]:
				paths.append(dir.path_join(exe))
			for dir in DirAccess.get_directories_at("/opt"):
				if dir.begins_with("blender"):
					paths.append("/opt".path_join(dir).path_join(exe))
			for root in ["/var/lib/flatpak", home.path_join(".local/share/flatpak")]:
				paths.append(root.path_join("exports/bin/org.blender.Blender"))
	var found := PackedStringArray()
	for path in paths:
		if not found.has(path) and FileAccess.file_exists(path):
			found.append(path)
	return found


## Blender 3.0+ installs as {path, version}, newest first. Paths through
## links to the same file count once, e.g. /bin/blender and /usr/bin/blender.
## Runs Blender, so call it from a thread.
static func detect() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var seen := {}
	for path in candidate_paths():
		var target := real_path(path)
		if seen.has(target):
			continue
		seen[target] = true
		var version := blender_version(path)
		if is_supported(version):
			result.append({"path": path, "version": version})
	result.sort_custom(func(a, b): return compare_versions(a.version, b.version))
	return result


## [param path] with links resolved in each part, like realpath.
static func real_path(path: String) -> String:
	var parts := path.simplify_path().split("/")
	var result := parts[0]
	var i := 1
	# A link loop gives up after this many links.
	var links := 0
	while i < parts.size():
		var dir_path := result if result else "/"
		var next := dir_path.path_join(parts[i])
		var dir := DirAccess.open(dir_path)
		if dir and dir.is_link(next) and links < 40:
			links += 1
			var target := dir.read_link(next)
			if not target.is_absolute_path():
				target = dir_path.path_join(target)
			# Resolve the target's parts too, then the rest of the path.
			var rest := parts.slice(i + 1)
			parts = target.simplify_path().split("/")
			parts.append_array(rest)
			result = parts[0]
			i = 1
			continue
		result = next
		i += 1
	return result
