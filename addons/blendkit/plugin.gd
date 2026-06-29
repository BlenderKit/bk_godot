@tool
extends EditorPlugin

const SERVER = "https://blendkit.com"
const CLIENT_PORTS = ["62485", "65425", "55428"]
#const CLIENT_PORTS = ["62485", "65425", "55428", "49452", "35452", "25152", "5152", "1234"]
const RESOLUTION_OPTIONS = ["", "ORIGINAL", "resolution_4K", "resolution_2K", "resolution_1K", "resolution_0_5K"]
const WAIT_OK: float = 0.8
const WAIT_EXPLORING: float = 0.2
const WAIT_STARTING: float = 1
const WAIT_STARTING_SLOW: float = 3
const STARTING_FAST_PROBES: int = 5
const STARTING_TIMEOUT: int = 30000
const REQUEST_TIMEOUT: int = 3000
# minimum process frames before a request can be considered timed out
# (guards against false timeouts when the main loop is suspended);
# non-threaded HTTPRequest polls once per frame and a request needs
# several polls to connect, send and read the response
const REQUEST_TIMEOUT_MIN_FRAMES: int = 10


enum LogLevel { ERROR, WARNING, INFO, VERBOSE, DEBUG, TRACE }

const LOG_LEVEL_NAMES = {
	LogLevel.ERROR: "ERROR",
	LogLevel.WARNING: "WARNING",
	LogLevel.INFO: "INFO",
	LogLevel.VERBOSE: "VERBOSE",
	LogLevel.DEBUG: "DEBUG",
	LogLevel.TRACE: "TRACE",
}

var log_level: int = LogLevel.INFO

# The Client reports message_level in Python logging values:
# 0=Debug, 10=Info, 20=Warning, 30=Error, 40=Fatal
static func client_message_log_level(message_level: int) -> LogLevel:
	if message_level >= 30:
		return LogLevel.ERROR
	if message_level >= 20:
		return LogLevel.WARNING
	if message_level >= 10:
		return LogLevel.INFO
	return LogLevel.DEBUG

func bk_log(level: LogLevel, msg: String) -> void:
	if level > log_level:
		return
	var prefix = "Blendkit: " if level == LogLevel.INFO else "Blendkit %s: " % LOG_LEVEL_NAMES[level]
	var log_msg = prefix + msg
	match level:
		LogLevel.ERROR:
			push_error(log_msg)
		LogLevel.WARNING:
			push_warning(log_msg)
		_:
			print(log_msg)


enum State { DISABLED, EXPLORING, STARTING, CONNECTED, FAILED }

const STATE_NAMES = {
	State.DISABLED: "DISABLED",
	State.EXPLORING: "EXPLORING",
	State.STARTING: "STARTING",
	State.CONNECTED: "CONNECTED",
	State.FAILED: "FAILED",
}

static func state_name(s: State) -> String:
	return STATE_NAMES.get(s, str(s))


const HTTP_CLIENT_STATUS_NAMES = {
	HTTPClient.STATUS_DISCONNECTED: "DISCONNECTED",
	HTTPClient.STATUS_RESOLVING: "RESOLVING",
	HTTPClient.STATUS_CANT_RESOLVE: "CANT_RESOLVE",
	HTTPClient.STATUS_CONNECTING: "CONNECTING",
	HTTPClient.STATUS_CANT_CONNECT: "CANT_CONNECT",
	HTTPClient.STATUS_CONNECTED: "CONNECTED",
	HTTPClient.STATUS_REQUESTING: "REQUESTING",
	HTTPClient.STATUS_BODY: "BODY",
	HTTPClient.STATUS_CONNECTION_ERROR: "CONNECTION_ERROR",
	HTTPClient.STATUS_TLS_HANDSHAKE_ERROR: "TLS_HANDSHAKE_ERROR",
}

static func http_status_name(status: int) -> String:
	return HTTP_CLIENT_STATUS_NAMES.get(status, str(status))


const HTTP_REQUEST_RESULT_NAMES = {
	HTTPRequest.RESULT_SUCCESS: "SUCCESS",
	HTTPRequest.RESULT_CHUNKED_BODY_SIZE_MISMATCH: "CHUNKED_BODY_SIZE_MISMATCH",
	HTTPRequest.RESULT_CANT_CONNECT: "CANT_CONNECT",
	HTTPRequest.RESULT_CANT_RESOLVE: "CANT_RESOLVE",
	HTTPRequest.RESULT_CONNECTION_ERROR: "CONNECTION_ERROR",
	HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR: "TLS_HANDSHAKE_ERROR",
	HTTPRequest.RESULT_NO_RESPONSE: "NO_RESPONSE",
	HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED: "BODY_SIZE_LIMIT_EXCEEDED",
	HTTPRequest.RESULT_BODY_DECOMPRESS_FAILED: "BODY_DECOMPRESS_FAILED",
	HTTPRequest.RESULT_REQUEST_FAILED: "REQUEST_FAILED",
	HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED: "REDIRECT_LIMIT_REACHED",
	HTTPRequest.RESULT_TIMEOUT: "TIMEOUT",
}

static func http_result_name(result: int) -> String:
	return HTTP_REQUEST_RESULT_NAMES.get(result, str(result))


var state: State = State.DISABLED
var fail_reason: String = ""

var download_dir: String = "res://bk_assets/"
var absolute_download_path: String
var model_format: String = "gltf_godot"
var resolution: String = ""
var port: String = CLIENT_PORTS[0]
var taken_ports: Array[String] = []
var failed_requests: int = 0
var max_failed_requests: int = 3
var request_start_time: int = 0
var request_start_frame: int = 0
var starting_since: int = 0
var http_request: HTTPRequest
var unsubscribe_http_request: HTTPRequest
var timer: Timer

# paths
var bk_plugin_dir: String
var client_data_dir: String
var client_version: String
var connected_client_version: String = ""
var client_base_dir: String
var client_bin_name: String
var client_bin_path: String

# GUI
const menu_scene = preload("res://addons/blendkit/menu.tscn")
const download_progress_bar_scene = preload("res://addons/blendkit/ui/download_progress_bar.tscn")
var docked_menu_scene: Control
var enabled_check_box: CheckBox
var status_icon: TextureRect
var status_label: Label
var port_option_button: OptionButton
var log_level_option_button: OptionButton
var version_label: Label
var browse_assets_button: Button
var download_directory: LineEdit
var model_format_option_button: OptionButton
var resolution_option_button: OptionButton
var downloads_container: VBoxContainer
var download_bars: Dictionary = {}


func _enter_tree():
	bk_log(LogLevel.INFO, "Plugin enabled")
	init_paths()
	bk_log(LogLevel.INFO, "Download path: %s" % absolute_download_path)
	bk_log(LogLevel.VERBOSE, "Client data dir: %s" % client_data_dir)

	http_request = HTTPRequest.new()
	add_child(http_request)
	http_request.request_completed.connect(on_request_completed)

	unsubscribe_http_request = HTTPRequest.new()
	add_child(unsubscribe_http_request)
	unsubscribe_http_request.request_completed.connect(on_unsubscribe_completed)

	timer = Timer.new()
	timer.one_shot = false
	timer.autostart = false
	add_child(timer)
	timer.timeout.connect(on_timer_timeout)

	init_ui()
	if enabled_check_box.is_pressed():
		enter_state(State.EXPLORING)


func _exit_tree():
	timer.queue_free()
	http_request.queue_free()
	unsubscribe_http_request.queue_free()
	cleanup_ui()
	bk_log(LogLevel.INFO, "Plugin exited")


func fail(reason: String):
	if state == State.CONNECTED:
		send_unsubscribe()
	fail_reason = reason
	state = State.FAILED
	timer.stop()
	http_request.cancel_request()
	bk_log(LogLevel.ERROR, "Client failed: %s. Please consider reporting this with your Output." % fail_reason)
	update_status()


func enter_state(new_state: State):
	# Centralized state transition code
	var prev_state := state
	state = new_state
	failed_requests = 0
	match new_state:
		State.DISABLED:
			if prev_state == State.CONNECTED:
				send_unsubscribe()
			bk_log(LogLevel.INFO, "Disabled")
			timer.stop()
			http_request.cancel_request()
		State.EXPLORING:
			port = CLIENT_PORTS[0]
			taken_ports.clear()
			timer.wait_time = WAIT_EXPLORING
			timer.start()
			bk_log(LogLevel.INFO, "Searching for running Client...")
		State.STARTING:
			starting_since = Time.get_ticks_msec()
			timer.wait_time = WAIT_STARTING
			timer.start()
			start_client(port)
		State.CONNECTED:
			timer.wait_time = WAIT_OK
			timer.start()
			if connected_client_version:
				bk_log(LogLevel.INFO, "Connected to Client v%s on port %s" % [connected_client_version, port])
			else:
				bk_log(LogLevel.INFO, "Connected to Client on port %s" % port)
		_:
			fail("invalid state %s" % state_name(new_state))

	update_status()


func update_status():
	match state:
		State.DISABLED:
			status_label.text = "Disabled"
		State.EXPLORING:
			status_label.text = "Exploring..."
		State.STARTING:
			var starting_elapsed := (Time.get_ticks_msec() - starting_since) / 1000
			status_label.text = "Starting (%d / %d s)..." % [starting_elapsed, STARTING_TIMEOUT / 1000]
		State.CONNECTED:
			if failed_requests > 0:
				status_label.text = "Reconnecting (#%s)..." % failed_requests
			else:
				status_label.text = "Connected (port %s)" % port
		State.FAILED:
			status_label.text = "Failed (%s)" % fail_reason
	if status_icon:
		status_icon.texture = get_state_icon()


func get_state_icon() -> Texture2D:
	var icon_name: String
	match state:
		State.DISABLED: icon_name = "NodeDisabled"
		State.EXPLORING: icon_name = "Search"
		State.STARTING: icon_name = "Timer"
		State.CONNECTED: icon_name = "StatusSuccess"
		State.FAILED: icon_name = "StatusError"
		_: return null
	return docked_menu_scene.get_theme_icon(icon_name, "EditorIcons")


func start_client(port: String):
	# look for client binaries again in case they were added
	find_packed_client()
	if not FileAccess.file_exists(client_bin_path):
		bk_log(LogLevel.ERROR, "Client binary not found. The plugin cannot work without the Client :(")
		bk_log(LogLevel.DEBUG, "Expected Client binary path: %s" % client_bin_path)
		fail("Client binary not found")
		return

	ensure_dir_structure() # so log's directory exists
	var log_path = get_client_log_path(port)
	var godot_pid = str(OS.get_process_id())
	var client_pid: int = 0
	var command_str: String = ""

	bk_log(LogLevel.INFO, "Starting Client v%s on port %s" % [client_version, port])
	# Godot's OS.create_process(), OS.execute() and similar does not support redirecting pipe to file, so we do it via shells

	if OS.has_feature("windows"):
		var win_log_path = log_path.replace("/", "\\")
		command_str = 'start /B "" "%s" -port %s -server %s -software Godot -pid %s > "%s" 2>&1' % [client_bin_path, port, SERVER, godot_pid, win_log_path]
		client_pid = OS.create_process("cmd.exe", ["/C", command_str])
	elif OS.has_feature("macos") or OS.has_feature("linux"):
		# The executable bit may be lost on extraction (e.g. when installed via the Godot Asset Store), so ensure it is set before launching
		command_str = 'chmod u+x "%s" && %s -port %s -server %s -software Godot -pid %s > "%s" 2>&1 &' % [client_bin_path, client_bin_path, port, SERVER, godot_pid, log_path]
		client_pid = OS.create_process("/bin/sh", ["-c", command_str])
	else:
		bk_log(LogLevel.ERROR, "Could not start client: Unsupported OS. Only Windows, MacOS and Linux are supported.")
		fail("unsupported OS")
		return

	if client_pid == 0:
		bk_log(LogLevel.ERROR, "Failed to start the Blendkit Client.")
		bk_log(LogLevel.DEBUG, "Failed command: %s" % command_str)
		fail("client start failed")
		return


func on_timer_timeout():
	if state in [State.FAILED, State.DISABLED]:
		bk_log(LogLevel.WARNING, "Timer fired in %s state - shouldn't happen" % state_name(state))
		return

	var http_client_status := http_request.get_http_client_status()
	var prev_request_failed := false
	if http_client_status != HTTPClient.STATUS_DISCONNECTED:
		bk_log(LogLevel.TRACE, "HTTP client: %s" % http_status_name(http_client_status))

	match http_client_status:
		HTTPClient.STATUS_CONNECTING:
			# Probably no-one listening on that port
			bk_log(LogLevel.DEBUG, "CONNECTING for too long on port %s" % port)
			prev_request_failed = true
		HTTPClient.STATUS_CONNECTED, HTTPClient.STATUS_BODY, HTTPClient.STATUS_REQUESTING:
			# Waiting for response - check timeout
			var elapsed := Time.get_ticks_msec() - request_start_time
			var frames_elapsed := Engine.get_process_frames() - request_start_frame
			if elapsed >= REQUEST_TIMEOUT:
				if frames_elapsed < REQUEST_TIMEOUT_MIN_FRAMES:
					# Wall-clock time passed but the request had (almost) no frames
					# to make progress - the main loop was suspended, e.g. by the
					# compositor hiding the window. Give it a frame to poll the
					# response that most likely already arrived.
					bk_log(LogLevel.DEBUG, "Main loop suspended for %d ms (%d frames) - postponing request timeout" % [elapsed, frames_elapsed])
					return
				bk_log(LogLevel.WARNING, "Request timeout in %s after %d ms (%d frames)" % [http_status_name(http_client_status), elapsed, frames_elapsed])
				prev_request_failed = true
			else:
				bk_log(LogLevel.DEBUG, "Waiting in %s (%d ms, %d frames)" % [http_status_name(http_client_status), elapsed, frames_elapsed])
				return
		HTTPClient.STATUS_DISCONNECTED:
			# Ready to request
			pass
		_:
			# Other states are unexpected errors
			prev_request_failed = true
			bk_log(LogLevel.WARNING, "HTTP client: %s" % http_status_name(http_client_status))

	if prev_request_failed:
		bk_log(LogLevel.TRACE, "HTTP request: cancelling request after client fail")
		http_request.cancel_request()
		request_failed()
		if state in [State.FAILED, State.DISABLED]:
			return

	if state == State.EXPLORING:
		bk_log(LogLevel.VERBOSE, "Exploring port %s..." % port)

	var url = "http://127.0.0.1:" + port + "/godot/report"
	var headers = ["Content-Type: application/json"]
	var data = {
		"name": "Godot",
		"appID": OS.get_process_id(),
		"version": get_godot_version(),
		"addonVersion": get_addon_version(),
		"assetsPath": absolute_download_path,
		"projectName": ProjectSettings.get_setting("application/config/name"),
		"modelFormat": model_format,
		"resolution": resolution,
	}
	var json = JSON.stringify(data)
	request_start_time = Time.get_ticks_msec()
	request_start_frame = Engine.get_process_frames()
	bk_log(LogLevel.TRACE, "POST %s  %s" % [url, json])
	var error = http_request.request(url, headers, HTTPClient.METHOD_POST, json)
	if error != OK:
		bk_log(LogLevel.ERROR, "Error sending request to %s, error=%s" % [url, error])
		http_request.cancel_request()
		request_failed()


func on_request_completed(result, response_code, _headers, body):
	var elapsed := Time.get_ticks_msec() - request_start_time
	if result != OK:
		bk_log(LogLevel.DEBUG, "Request %s, response_code=%d, state=%s, port=%s" % [http_result_name(result), response_code, state_name(state), port])
	if state in [State.DISABLED, State.FAILED]:
		bk_log(LogLevel.WARNING, "Ignoring stale request completion in %s state" % state_name(state))
		return

	var body_text: String = body.get_string_from_utf8()
	bk_log(LogLevel.TRACE, "HTTP response (%d ms): %s" % [elapsed, body_text])

	# Success - only a 200 with a valid JSON body counts as the Client
	if response_code == 200:
		var data = JSON.parse_string(body_text)
		if typeof(data) == TYPE_DICTIONARY:
			if state != State.CONNECTED:
				var found_version := str(data.get("client_version", ""))
				# Skip a discovered Client that is older than the one we bundle.
				# Only while exploring - a Client we started ourselves matches the
				# bundled version and must never be rejected here.
				if state == State.EXPLORING and version_lt(found_version, client_version):
					var found_label := found_version if found_version else "(unknown)"
					bk_log(LogLevel.INFO, "Skipping Client v%s on port %s: older than required v%s" % [found_label, port, client_version])
					if not taken_ports.has(port):
						taken_ports.append(port)
					request_failed()
					return
				connected_client_version = found_version
				enter_state(State.CONNECTED)
			elif failed_requests > 0:
				failed_requests = 0
				update_status()

			var msg = data.get("message", "")
			if msg:
				var level := client_message_log_level(int(data.get("message_level", 10)))
				bk_log(level, "Client: %s" % msg)
			var tasks = data.get("tasks", [])
			if tasks:
				handle_tasks(tasks)
			return
		bk_log(LogLevel.WARNING, "Got 200 on port %s but body is not a valid JSON object - not the Client?" % port)

	if state == State.EXPLORING:
		bk_log(LogLevel.VERBOSE, "Client not found on port %s" % port)
	elif response_code != 200:
		bk_log(LogLevel.WARNING, "Request on port %s failed (response_code=%d)" % [port, response_code])
	if body_text != "":
		bk_log(LogLevel.TRACE, "Response body: %s" % body_text)

	request_failed()


func request_failed():
	failed_requests += 1

	if state == State.EXPLORING:
		var port_index = CLIENT_PORTS.find(port)
		port_index += 1
		if port_index < CLIENT_PORTS.size():
			port = CLIENT_PORTS[port_index]
		else:
			port = choose_start_port()
			bk_log(LogLevel.VERBOSE, "No running Client found")
			enter_state(State.STARTING)

	elif state == State.STARTING:
		var starting_elapsed := Time.get_ticks_msec() - starting_since
		if starting_elapsed >= STARTING_TIMEOUT:
			bk_log(LogLevel.ERROR, "Failed to connect to Client on port %s after %s tries in %d ms." % [port, failed_requests, starting_elapsed])
			fail("connection timeout")
			return
		if failed_requests == STARTING_FAST_PROBES:
			bk_log(LogLevel.VERBOSE, "Client not up after %d fast probes, slowing probes to %ss" % [STARTING_FAST_PROBES, WAIT_STARTING_SLOW])
			timer.wait_time = WAIT_STARTING_SLOW
			timer.start()
		update_status()

	elif state == State.CONNECTED:
		if failed_requests >= max_failed_requests:
			bk_log(LogLevel.WARNING, "Lost connection to Blendkit Client on port %s." % port)
			enter_state(State.EXPLORING)
			return
		update_status()

	else:
		bk_log(LogLevel.ERROR, "Unexpected state: %s" % state_name(state))
		fail("unexpected state")


func choose_start_port() -> String:
	# The UI-selected port is the desired port, but discovery may have found an
	# unusable Client already running on it. In that case start on another known
	# port that we did not find occupied.
	var selected_index := port_option_button.get_selected()
	var desired := port_option_button.get_item_text(selected_index)
	if not taken_ports.has(desired):
		return desired

	bk_log(LogLevel.INFO, "Desired port %s is occupied by an older Client, choosing another port..." % desired)
	for i in port_option_button.item_count:
		var candidate := port_option_button.get_item_text(i)
		if not taken_ports.has(candidate):
			bk_log(LogLevel.INFO, "Selected port %s for the Client" % candidate)
			return candidate

	bk_log(LogLevel.WARNING, "All known ports are occupied, falling back to %s" % desired)
	return desired


func send_unsubscribe():
	var url = "http://127.0.0.1:" + port + "/godot/unsubscribe_addon"
	var headers = ["Content-Type: application/json"]
	var data = JSON.stringify({"app_id": OS.get_process_id()})
	bk_log(LogLevel.INFO, "Disconnecting from Client on port %s" % port)
	var error = unsubscribe_http_request.request(url, headers, HTTPClient.METHOD_POST, data)
	if error != OK:
		bk_log(LogLevel.WARNING, "Failed to send unsubscribe request: %s" % error)


func on_unsubscribe_completed(result, response_code, _headers, _body):
	if result != OK or response_code != 200:
		bk_log(LogLevel.WARNING, "Unsubscribe request failed on port %s: result=%s, response_code=%d" % [port, http_result_name(result), response_code])
	else:
		bk_log(LogLevel.VERBOSE, "Unsubscribed from Client on port %s" % port)


func on_enabled_toggled(enabled: bool):
	if enabled:
		enter_state(State.EXPLORING)
	else:
		enter_state(State.DISABLED)


func on_browse_assets_pressed():
	OS.shell_open(SERVER)


func on_download_dir_submitted(_text: String = ""):
	download_dir = download_directory.text
	absolute_download_path = ProjectSettings.globalize_path(download_dir)
	bk_log(LogLevel.INFO, "Download path set to: %s" % absolute_download_path)


func on_log_level_changed(index: int):
	log_level = index
	bk_log(LogLevel.INFO, "Log level set to %s" % LOG_LEVEL_NAMES[log_level])


func on_model_format_changed(index: int):
	model_format = "gltf_godot" if index == 0 else "blend"
	ProjectSettings.set_setting("blendkit/model_format", model_format)


func on_resolution_changed(index: int):
	resolution = RESOLUTION_OPTIONS[index]
	ProjectSettings.set_setting("blendkit/resolution", resolution)


func init_paths():
	absolute_download_path = ProjectSettings.globalize_path(download_dir)
	client_bin_name = get_client_binary_name()
	client_data_dir = get_client_data_dir()
	bk_plugin_dir = self.get_script().resource_path.get_base_dir()
	client_base_dir = bk_plugin_dir.path_join("client")
	find_packed_client()


func find_packed_client():
	client_version = get_version_from_dir(client_base_dir)
	client_bin_path = get_packed_client_binary_path()


func init_ui():
	docked_menu_scene = menu_scene.instantiate()
	add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_UL, docked_menu_scene)
	enabled_check_box = docked_menu_scene.get_node("EnabledCheckBox")
	enabled_check_box.toggled.connect(on_enabled_toggled)
	status_icon = docked_menu_scene.get_node("StatusRow/StatusIcon")
	status_label = docked_menu_scene.get_node("StatusRow/StatusLabel")
	port_option_button = docked_menu_scene.get_node("Port/OptionButton")
	version_label = docked_menu_scene.get_node("DocsContainer/Version")
	version_label.text = "Blendkit v%s" % get_addon_version()
	browse_assets_button = docked_menu_scene.get_node("BrowseAssets")
	browse_assets_button.pressed.connect(on_browse_assets_pressed)
	download_directory = docked_menu_scene.get_node("DownloadTo/LineEdit")
	download_directory.text_submitted.connect(on_download_dir_submitted)
	download_directory.focus_exited.connect(on_download_dir_submitted)
	log_level_option_button = docked_menu_scene.get_node("LogLevel/OptionButton")
	log_level_option_button.selected = log_level
	log_level_option_button.item_selected.connect(on_log_level_changed)
	model_format_option_button = docked_menu_scene.get_node("ModelFormat/OptionButton")
	model_format = ProjectSettings.get_setting("blendkit/model_format", "gltf_godot")
	model_format_option_button.selected = 0 if model_format == "gltf_godot" else 1
	model_format_option_button.item_selected.connect(on_model_format_changed)
	resolution_option_button = docked_menu_scene.get_node("Resolution/OptionButton")
	resolution = ProjectSettings.get_setting("blendkit/resolution", "")
	resolution_option_button.selected = max(0, RESOLUTION_OPTIONS.find(resolution))
	resolution_option_button.item_selected.connect(on_resolution_changed)
	downloads_container = docked_menu_scene.get_node("DownloadsContainer")
	update_status()


func cleanup_ui():
	download_bars.clear()
	remove_control_from_docks(docked_menu_scene)
	docked_menu_scene.queue_free()


func handle_tasks(tasks: Array) -> void:
	for task in tasks:
		if task.get("task_type") != "asset_download":
			continue
		var task_id: String = task.get("task_id", "")
		if task_id == "":
			continue

		var bar
		if download_bars.has(task_id):
			bar = download_bars[task_id]
		else:
			bar = download_progress_bar_scene.instantiate()
			downloads_container.add_child(bar)
			downloads_container.move_child(bar, 0)
			download_bars[task_id] = bar

		bar.apply_task(task)

		var status: String = task.get("status", "")
		if status in ["finished", "error"]:
			download_bars.erase(task_id)


func get_addon_version():
	var config = ConfigFile.new()
	var err = config.load("res://addons/blendkit/plugin.cfg")
	if err != OK:
		return "unknown"
	return config.get_value("plugin", "version", "unknown")


func get_godot_version():
	return str(Engine.get_version_info()["major"]) + "." + str(Engine.get_version_info()["minor"]) + "." + str(Engine.get_version_info()["patch"])


func get_packed_client_binary_path():
	var bin_path = client_base_dir.path_join("v" + client_version).path_join(client_bin_name)
	return ProjectSettings.globalize_path(bin_path)


func get_client_log_path(log_port: String) -> String:
	# TODO: create the file if it does not exist
	if log_port == CLIENT_PORTS[0]:
		return client_data_dir.path_join("default.log")
	return client_data_dir.path_join("%s.log" % log_port)


static func get_client_data_dir():
	var home_path := ""
	if OS.has_feature("windows"):
		home_path = OS.get_environment("USERPROFILE")
	else:
		home_path = OS.get_environment("HOME")
	return home_path.path_join("blenderkit_data").path_join("client")


static func get_client_binary_name() -> String:
	var arch = Engine.get_architecture_name()
	if OS.has_feature("windows"):
		return "blenderkit-client-windows-" + arch + ".exe"
	if OS.has_feature("macos"):
		return "blenderkit-client-macos-" + arch
	if OS.has_feature("linux"):
		return "blenderkit-client-linux-" + arch
	return ""


static func get_version_from_dir(base_dir: String) -> String:
	var dir = DirAccess.open(base_dir)
	if not dir:
		return ""

	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if dir.current_is_dir() and file_name.begins_with("v"):
			var version = file_name.substr(1) # Remove 'v'
			dir.list_dir_end()
			return version
		file_name = dir.get_next()

	dir.list_dir_end()
	return ""


static func parse_version_parts(version: String) -> Array:
	# Extract the numeric components of a version string, e.g.
	# "1.9.1-260127" -> [1, 9, 1, 260127]. Mirrors the Client's
	# tolerant comparator (BlenderKit/version_compare.py).
	var parts: Array[int] = []
	var regex := RegEx.new()
	regex.compile("\\d+")
	for m in regex.search_all(version):
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


func ensure_dir_structure():
	DirAccess.make_dir_recursive_absolute(client_data_dir)
