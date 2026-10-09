@tool
extends RefCounted
## The Blendkit Client executable bundled in the addon's client/ folder:
## which version to run, a shared copy outside the project, and launching it.

const CLIENT_API_VERSION = "v1.13"
# Client versions of the supported API series, e.g. "1.13.6" for v1.13.
static var _client_version_regex := RegEx.create_from_string("^" + CLIENT_API_VERSION.substr(1).replace(".", "\\.") + "\\.[0-9]+$")
static var _digits_regex := RegEx.create_from_string("\\d+")

## The bundled version, e.g. "1.13.6", or "" if none was found.
var version: String
## The executable to launch, the shared copy once installed.
var bin_path: String

var _plugin: EditorPlugin
var _base_dir: String
var _bin_name: String


func _init(plugin: EditorPlugin, base_dir: String) -> void:
	_plugin = plugin
	_base_dir = base_dir
	_bin_name = get_client_binary_name()
	find_packed()


func find_packed() -> void:
	version = ""
	var marker := _base_dir.path_join("RESOLVED_VERSION")
	if FileAccess.file_exists(marker):
		var resolved := FileAccess.get_file_as_string(marker).strip_edges()
		if resolved.begins_with("v") and is_valid_client_version(resolved.substr(1)):
			version = resolved.substr(1)
		else:
			_plugin.log_error("Invalid Client RESOLVED_VERSION: %s" % resolved)
	else:
		version = pick_highest_version(list_client_versions(_base_dir))
	bin_path = ProjectSettings.globalize_path(_base_dir.path_join("v" + version).path_join(_bin_name))


## Starts the Client on [param port], logging to [param log_path]. Returns
## why it couldn't, or "" when it started.
func launch(port: String, server: String, log_path: String) -> String:
	# look for client binaries again in case they were added
	find_packed()
	if not FileAccess.file_exists(bin_path):
		_plugin.log_error("Client binary not found. The plugin cannot work without the Client :(")
		_plugin.log_debug("Expected Client binary path: %s" % bin_path)
		return "Client binary not found"

	DirAccess.make_dir_recursive_absolute(log_path.get_base_dir())
	install_shared()
	var godot_pid = str(OS.get_process_id())
	var client_pid: int = 0
	var command_str: String = ""

	_plugin.log_info("Starting Client v%s on port %s" % [version, port])
	# Godot's OS.create_process(), OS.execute() and similar does not support redirecting pipe to file, so we do it via shells

	if OS.has_feature("windows"):
		var win_log_path = log_path.replace("/", "\\")
		command_str = 'start /B "" "%s" -port %s -server %s -software Godot -pid %s > "%s" 2>&1' % [bin_path, port, server, godot_pid, win_log_path]
		client_pid = OS.create_process("cmd.exe", ["/C", command_str])
	elif OS.has_feature("macos") or OS.has_feature("linux"):
		# The executable bit may be lost on extraction (e.g. when installed via the Godot Asset Store), so ensure it is set before launching
		command_str = 'chmod u+x "$1" && exec "$1" -port "$2" -server "$3" -software Godot -pid "$4" > "$5" 2>&1'
		# Positional arguments keep spaces and shell metacharacters literal.
		client_pid = OS.create_process("/bin/sh", ["-c", command_str, "bk_client", bin_path, port, server, godot_pid, log_path])
	else:
		_plugin.log_error("Could not start client: Unsupported OS. Only Windows, MacOS and Linux are supported.")
		return "unsupported OS"

	if client_pid <= 0:
		_plugin.log_error("Failed to start the Blendkit Client.")
		_plugin.log_debug("Failed command: %s" % command_str)
		return "client start failed"
	return ""


func install_shared() -> void:
	# Run outside the project so a running executable does not block plugin updates.
	var target_dir := get_client_data_dir().path_join("bin").path_join("v" + version)
	var target := target_dir.path_join(_bin_name)
	if FileAccess.file_exists(target) and FileAccess.get_sha256(target) == FileAccess.get_sha256(bin_path):
		bin_path = target
		return
	if DirAccess.make_dir_recursive_absolute(target_dir) == OK:
		# Stage per process before replacing an outdated shared copy.
		var temporary := target + "." + str(OS.get_process_id()) + ".tmp"
		if DirAccess.copy_absolute(bin_path, temporary) == OK:
			if DirAccess.rename_absolute(temporary, target) == OK:
				bin_path = target
				return
			DirAccess.remove_absolute(temporary)
	_plugin.log_warning("Shared Client installation unavailable; running bundled executable")


static func is_valid_client_version(client_version: String) -> bool:
	return _client_version_regex.search(client_version) != null


## Requires the supported API series and at least the bundled patch.
static func is_compatible_client(found: String, required: String) -> bool:
	return is_valid_client_version(found) and not version_lt(found, required)


static func get_client_data_dir() -> String:
	var home_path := ""
	if OS.has_feature("windows"):
		home_path = OS.get_environment("USERPROFILE")
	else:
		home_path = OS.get_environment("HOME")
	return home_path.path_join("blenderkit_data").path_join("client")


static func get_client_binary_name() -> String:
	var arch = Engine.get_architecture_name()
	if OS.has_feature("windows"):
		return "bk_client-windows-" + arch + ".exe"
	if OS.has_feature("macos"):
		return "bk_client-macos-" + arch
	if OS.has_feature("linux"):
		return "bk_client-linux-" + arch
	return ""


static func list_client_versions(base_dir: String) -> Array:
	# Collect the version string of every "vX.Y.Z" client folder in base_dir.
	var versions: Array[String] = []
	var dir = DirAccess.open(base_dir)
	if not dir:
		return versions

	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if dir.current_is_dir() and file_name.begins_with("v") and is_valid_client_version(file_name.substr(1)) and FileAccess.file_exists(base_dir.path_join(file_name).path_join(get_client_binary_name())):
			versions.append(file_name.substr(1)) # Remove 'v'
		file_name = dir.get_next()

	dir.list_dir_end()
	return versions


static func pick_highest_version(versions: Array) -> String:
	# Return the highest version using the tolerant comparator, or "" if none.
	var highest := ""
	for v in versions:
		if highest == "" or version_lt(highest, v):
			highest = v
	return highest


static func parse_version_parts(client_version: String) -> Array:
	# Extract the numeric components of a version string, e.g.
	# "1.9.1-260127" -> [1, 9, 1, 260127]. Mirrors the Client's
	# tolerant comparator (BlenderKit/version_compare.py).
	var parts: Array[int] = []
	for m in _digits_regex.search_all(client_version):
		parts.append(int(m.get_string()))
	return parts


static func version_lt(a: String, b: String) -> bool:
	# True if version `a` is strictly older than version `b`, comparing
	# numeric parts left to right. A missing/shorter prefix sorts lower,
	# so an empty/unparseable version counts as older than any real one.
	var pa := parse_version_parts(a)
	var pb := parse_version_parts(b)
	var n := mini(pa.size(), pb.size())
	for i in n:
		if pa[i] != pb[i]:
			return pa[i] < pb[i]
	return pa.size() < pb.size()
