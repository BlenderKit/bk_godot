@tool
extends EditorPlugin

signal model_format_changed

const SERVER = "https://blendkit.com"
const CLIENT_API_VERSION = "v1.13"
const CLIENT_PORTS = ["62485", "65425", "55428", "49452", "35452", "25152", "5152", "1234"]
# [value, label] pairs for the settings dialog
const MODEL_FORMATS = [["blend", "Blender original (.blend)"], ["gltf_godot", "glTF (.glb) when available"]]
const RESOLUTIONS = [["", "Auto"], ["ORIGINAL", "Original"], ["resolution_4K", "4K"], ["resolution_2K", "2K"], ["resolution_1K", "1K"], ["resolution_0_5K", "0.5K"]]
# Project settings live in project.godot and are shared with the team, editor
# settings stay on this computer. All of them show in Godot's settings dialogs.
const SETTING_DOWNLOAD_DIR = "blendkit/downloads/directory"
const SETTING_MODEL_FORMAT = "blendkit/downloads/model_format"
const SETTING_RESOLUTION = "blendkit/downloads/resolution"
const SETTING_CLIENT_ENABLED = "blendkit/client/enabled"
const SETTING_PORT = "blendkit/client/port"
const SETTING_LOG_LEVEL = "blendkit/client/log_level"
# Older keys moved to the settings above.
const OLD_SETTINGS = {"blendkit/model_format": SETTING_MODEL_FORMAT, "blendkit/resolution": SETTING_RESOLUTION}
# Godot's enum hints can't hold an empty value, so Auto resolution "" is stored as this.
const RESOLUTION_AUTO = "auto"
const DOCS_URL = "https://github.com/BlenderKit/bk_godot"
const ISSUES_URL = "https://github.com/BlenderKit/bk_godot/issues"
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
const MAX_FAILED_REQUESTS: int = 3


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
var client_enabled := true

var download_dir: String = "res://bk_assets/"
var absolute_download_path: String
var model_format: String = "blend"
var resolution: String = ""
var port: String = CLIENT_PORTS[0]
# Port to start the Client on when none is running
var preferred_port: String = CLIENT_PORTS[0]
var taken_ports: Array[String] = []
var failed_requests: int = 0
var request_start_time: int = 0
var request_start_frame: int = 0
var starting_since: int = 0
var http_request: HTTPRequest
var unsubscribe_http_request: HTTPRequest
var timer: Timer

# paths
var client_data_dir: String
var client_version: String
var connected_client_version: String = ""
var client_base_dir: String
var client_bin_name: String
var client_bin_path: String
var addon_version: String

# GUI
const gallery_scene = preload("res://addons/blendkit/ui/gallery/gallery.tscn")
const Auth = preload("res://addons/blendkit/auth.gd")
const GalleryApi = preload("res://addons/blendkit/ui/gallery/gallery_api.gd")
# Monochrome editor tab icon, drawn in #e0e0e0 like the built-in editor icons.
const ICON_PATH = "res://addons/blendkit/logo/blendkit-icon.svg"
const LOGO_PATH = "res://addons/blendkit/logo/blendkit-logo-hexa_pure.svg"
const LOGO_SVG_SIZE = 320.0
var gallery: Control
var auth: Auth
var plugin_icon: Texture2D
var plugin_icon_key: String
# Category tree from the Client's categories_update task, used by the gallery
var categories: Array = []


func _enter_tree():
	init_settings()
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

	auth = Auth.new()
	auth.plugin = self
	add_child(auth)

	init_gallery()
	ProjectSettings.settings_changed.connect(load_settings)
	EditorInterface.get_editor_settings().settings_changed.connect(load_settings)
	if client_enabled:
		enter_state(State.EXPLORING)


# No unsubscribe here: on editor shutdown the request never reaches the
# Client, as the HTTPRequest is freed with the plugin before it's sent.
func _exit_tree():
	ProjectSettings.settings_changed.disconnect(load_settings)
	EditorInterface.get_editor_settings().settings_changed.disconnect(load_settings)
	timer.queue_free()
	http_request.queue_free()
	unsubscribe_http_request.queue_free()
	if gallery:
		gallery.queue_free()
		gallery = null
	auth.queue_free()
	bk_log(LogLevel.INFO, "Plugin exited")


# Main screen tab. _has_main_screen() is deprecated in Godot 4.8 in favor of an
# EditorDock in DOCK_SLOT_MAIN_SCREEN, but it still works and is the only
# option on Godot 4.0-4.7.
func _has_main_screen() -> bool:
	return true


func _make_visible(visible: bool) -> void:
	if gallery:
		gallery.visible = visible


func _get_plugin_name() -> String:
	return "Blendkit"


# Godot asks again on theme changes, so the icon follows the editor scale and
# light/dark icon colors.
func _get_plugin_icon() -> Texture2D:
	var scale := EditorInterface.get_editor_scale()
	var key := "%s %s" % [scale, is_dark_icon_theme()]
	if plugin_icon and plugin_icon_key == key:
		return plugin_icon
	plugin_icon = render_svg(ICON_PATH, scale, true)
	plugin_icon_key = key
	return plugin_icon


## Renders the SVG at [param scale] times its size, e.g. the editor scale for
## a 16 px icon, so it stays crisp. Monochrome icons turn dark on light themes.
static func render_svg(path: String, scale: float, monochrome := false) -> Texture2D:
	var svg := FileAccess.get_file_as_string(path)
	if monochrome and not is_dark_icon_theme():
		# Same conversion as Godot does for its own icons on light themes.
		svg = svg.replace("#e0e0e0", "#5a5a5a")
	var image := Image.new()
	if svg.is_empty() or image.load_svg_from_string(svg, scale) != OK:
		return null
	return ImageTexture.create_from_image(image)


## The colored Blendkit logo, [param px] pixels wide.
static func render_logo(px: float) -> Texture2D:
	return render_svg(LOGO_PATH, px / LOGO_SVG_SIZE)


# Mirrors EditorThemeManager::is_dark_icon_and_font(): light icons and fonts
# on a dark theme.
static func is_dark_icon_theme() -> bool:
	var settings := EditorInterface.get_editor_settings()
	match settings.get_setting("interface/theme/icon_and_font_color"):
		1: return false # dark icons
		2: return true # light icons
	var base_color: Color = settings.get_setting("interface/theme/base_color")
	return base_color.get_luminance() < 0.5


func fail(reason: String):
	if state == State.CONNECTED:
		send_unsubscribe()
	fail_reason = reason
	state = State.FAILED
	timer.stop()
	http_request.cancel_request()
	bk_log(LogLevel.ERROR, "Client failed: %s. Please consider reporting this with your Output." % fail_reason)
	auth.on_client_lost()
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
			auth.on_client_lost()
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
			update_poll_rate()
			if connected_client_version:
				bk_log(LogLevel.INFO, "Connected to Client v%s on port %s" % [connected_client_version, port])
			else:
				bk_log(LogLevel.INFO, "Connected to Client on port %s" % port)
			auth.on_connected()
		_:
			fail("invalid state %s" % state_name(new_state))

	update_status()


func update_status():
	if gallery:
		gallery.on_connection_changed()


func status_text() -> String:
	match state:
		State.DISABLED:
			return "Disabled"
		State.EXPLORING:
			return "Looking for Client…"
		State.STARTING:
			var starting_elapsed := (Time.get_ticks_msec() - starting_since) / 1000
			return "Starting (%d / %d s)…" % [starting_elapsed, STARTING_TIMEOUT / 1000]
		State.CONNECTED:
			if failed_requests > 0:
				return "Reconnecting (#%s)…" % failed_requests
			return "Connected (port %s)" % port
		State.FAILED:
			return "Failed (%s)" % fail_reason
	return state_name(state)


func get_state_icon() -> Texture2D:
	var icon_name: String
	match state:
		State.DISABLED: icon_name = "NodeDisabled"
		State.EXPLORING: icon_name = "Search"
		State.STARTING: icon_name = "Timer"
		State.CONNECTED: icon_name = "StatusSuccess"
		State.FAILED: icon_name = "StatusError"
		_: return null
	return EditorInterface.get_editor_theme().get_icon(icon_name, "EditorIcons")


func start_client(port: String):
	# look for client binaries again in case they were added
	find_packed_client()
	if not FileAccess.file_exists(client_bin_path):
		bk_log(LogLevel.ERROR, "Client binary not found. The plugin cannot work without the Client :(")
		bk_log(LogLevel.DEBUG, "Expected Client binary path: %s" % client_bin_path)
		fail("Client binary not found")
		return

	DirAccess.make_dir_recursive_absolute(client_data_dir) # so the log's directory exists
	install_shared_client()
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
		command_str = 'chmod u+x "$1" && exec "$1" -port "$2" -server "$3" -software Godot -pid "$4" > "$5" 2>&1'
		# Positional arguments keep spaces and shell metacharacters literal.
		client_pid = OS.create_process("/bin/sh", ["-c", command_str, "bk_client", client_bin_path, port, SERVER, godot_pid, log_path])
	else:
		bk_log(LogLevel.ERROR, "Could not start client: Unsupported OS. Only Windows, MacOS and Linux are supported.")
		fail("unsupported OS")
		return

	if client_pid <= 0:
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
	elif state == State.CONNECTED:
		update_poll_rate()

	var url := client_url("godot/report")
	var headers = ["Content-Type: application/json"]
	var data = {
		"name": "Godot",
		"appID": OS.get_process_id(),
		"version": get_godot_version(),
		"addonVersion": get_addon_version(),
		# Send to Godot downloads there, see GalleryApi.STAGING_DIR.
		"assetsPath": GalleryApi.staging_path(absolute_download_path),
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
				# Require the supported API series and at least the bundled patch.
				if not is_compatible_client(found_version, client_version):
					var found_label := found_version if found_version else "(unknown)"
					bk_log(LogLevel.INFO, "Skipping Client v%s on port %s: incompatible with required v%s" % [found_label, port, client_version])
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
			handle_tasks(tasks if tasks is Array else [])
			return
		bk_log(LogLevel.WARNING, "Got 200 on port %s but body is not a valid JSON object - not the Client?" % port)

	if state == State.EXPLORING:
		# Any HTTP response means the port is occupied, including a different API series.
		if response_code > 0 and not taken_ports.has(port):
			taken_ports.append(port)
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
		if failed_requests >= MAX_FAILED_REQUESTS:
			bk_log(LogLevel.WARNING, "Lost connection to Blendkit Client on port %s." % port)
			enter_state(State.EXPLORING)
			return
		update_status()

	else:
		bk_log(LogLevel.ERROR, "Unexpected state: %s" % state_name(state))
		fail("unexpected state")


# Poll faster while the gallery waits for search results, thumbnails or
# downloads, which all arrive through /godot/report.
func update_poll_rate():
	if state != State.CONNECTED:
		return
	var wait := WAIT_EXPLORING if gallery and gallery.has_pending_work() else WAIT_OK
	if is_equal_approx(timer.wait_time, wait):
		return
	timer.wait_time = wait
	if timer.time_left > wait:
		timer.start()


func choose_start_port() -> String:
	# The preferred port is the desired port, but discovery may have found an
	# unusable Client already running on it. In that case start on another known
	# port that we did not find occupied.
	var desired := preferred_port
	if not taken_ports.has(desired):
		return desired

	bk_log(LogLevel.INFO, "Desired port %s is occupied by an incompatible Client, choosing another port..." % desired)
	for candidate in CLIENT_PORTS:
		if not taken_ports.has(candidate):
			bk_log(LogLevel.INFO, "Selected port %s for the Client" % candidate)
			return candidate

	bk_log(LogLevel.WARNING, "All known ports are occupied, falling back to %s" % desired)
	return desired


func send_unsubscribe():
	var url := client_url("addons/unsubscribe")
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


func set_client_enabled(enabled: bool):
	if enabled == client_enabled:
		return
	client_enabled = enabled
	EditorInterface.get_editor_settings().set_setting(SETTING_CLIENT_ENABLED, enabled)
	if enabled:
		enter_state(State.EXPLORING)
	else:
		enter_state(State.DISABLED)


func restart_client():
	set_client_enabled(false)
	set_client_enabled(true)


func set_download_dir(dir: String):
	if dir == download_dir:
		return
	download_dir = dir
	save_project_setting(SETTING_DOWNLOAD_DIR, download_dir)
	absolute_download_path = ProjectSettings.globalize_path(download_dir)
	bk_log(LogLevel.INFO, "Download path set to: %s" % absolute_download_path)


func set_log_level(level: int):
	if level == log_level:
		return
	log_level = level
	EditorInterface.get_editor_settings().set_setting(SETTING_LOG_LEVEL, log_level)
	bk_log(LogLevel.INFO, "Log level set to %s" % LOG_LEVEL_NAMES[log_level])


func set_preferred_port(new_port: String):
	if new_port == preferred_port:
		return
	preferred_port = new_port
	EditorInterface.get_editor_settings().set_setting(SETTING_PORT, preferred_port)


func set_model_format(format: String):
	if format == model_format:
		return
	model_format = format
	save_project_setting(SETTING_MODEL_FORMAT, model_format)
	model_format_changed.emit()


func set_resolution(new_resolution: String):
	if new_resolution == resolution:
		return
	resolution = new_resolution
	save_project_setting(SETTING_RESOLUTION, RESOLUTION_AUTO if resolution.is_empty() else resolution)


# MARK: settings

## Registers the settings with Godot and reads them, without side effects
## so it can run before the plugin is set up.
func init_settings() -> void:
	add_project_setting(SETTING_DOWNLOAD_DIR, download_dir, PROPERTY_HINT_DIR)
	add_project_setting(SETTING_MODEL_FORMAT, model_format, PROPERTY_HINT_ENUM,
		",".join(MODEL_FORMATS.map(func(f): return f[0])))
	add_project_setting(SETTING_RESOLUTION, RESOLUTION_AUTO, PROPERTY_HINT_ENUM,
		",".join(RESOLUTIONS.map(func(r): return r[0] if r[0] else RESOLUTION_AUTO)))
	add_editor_setting(SETTING_CLIENT_ENABLED, client_enabled)
	add_editor_setting(SETTING_PORT, preferred_port, PROPERTY_HINT_ENUM, ",".join(CLIENT_PORTS))
	add_editor_setting(SETTING_LOG_LEVEL, log_level, PROPERTY_HINT_ENUM, ",".join(LOG_LEVEL_NAMES.values()))
	# After registering, so migrated defaults aren't written to project.godot.
	for old in OLD_SETTINGS:
		if ProjectSettings.has_setting(old):
			var value = ProjectSettings.get_setting(old)
			ProjectSettings.set_setting(OLD_SETTINGS[old], RESOLUTION_AUTO if str(value).is_empty() else value)
			ProjectSettings.set_setting(old, null)
			ProjectSettings.save()

	var editor_settings := EditorInterface.get_editor_settings()
	download_dir = ProjectSettings.get_setting(SETTING_DOWNLOAD_DIR)
	model_format = ProjectSettings.get_setting(SETTING_MODEL_FORMAT)
	resolution = _resolution_setting()
	client_enabled = editor_settings.get_setting(SETTING_CLIENT_ENABLED)
	preferred_port = editor_settings.get_setting(SETTING_PORT)
	log_level = editor_settings.get_setting(SETTING_LOG_LEVEL)


## Applies settings changed elsewhere, e.g. in Godot's settings dialogs.
func load_settings() -> void:
	var editor_settings := EditorInterface.get_editor_settings()
	set_log_level(editor_settings.get_setting(SETTING_LOG_LEVEL))
	set_download_dir(ProjectSettings.get_setting(SETTING_DOWNLOAD_DIR))
	set_model_format(ProjectSettings.get_setting(SETTING_MODEL_FORMAT))
	set_resolution(_resolution_setting())
	set_preferred_port(editor_settings.get_setting(SETTING_PORT))
	set_client_enabled(editor_settings.get_setting(SETTING_CLIENT_ENABLED))


func _resolution_setting() -> String:
	var value: String = ProjectSettings.get_setting(SETTING_RESOLUTION)
	return "" if value == RESOLUTION_AUTO else value


static func add_project_setting(key: String, default: Variant, hint := PROPERTY_HINT_NONE, hint_string := "") -> void:
	if not ProjectSettings.has_setting(key):
		ProjectSettings.set_setting(key, default)
	ProjectSettings.add_property_info({"name": key, "type": typeof(default), "hint": hint, "hint_string": hint_string})
	# Values equal to the initial one aren't written to project.godot.
	ProjectSettings.set_initial_value(key, default)
	ProjectSettings.set_as_basic(key, true)


static func add_editor_setting(key: String, default: Variant, hint := PROPERTY_HINT_NONE, hint_string := "") -> void:
	var settings := EditorInterface.get_editor_settings()
	if not settings.has_setting(key):
		settings.set_setting(key, default)
	settings.add_property_info({"name": key, "type": typeof(default), "hint": hint, "hint_string": hint_string})
	settings.set_initial_value(key, default, false)


static func save_project_setting(key: String, value: Variant) -> void:
	ProjectSettings.set_setting(key, value)
	ProjectSettings.save()


func init_paths():
	absolute_download_path = ProjectSettings.globalize_path(download_dir)
	client_bin_name = get_client_binary_name()
	client_data_dir = get_client_data_dir()
	client_base_dir = get_script().resource_path.get_base_dir().path_join("client")
	find_packed_client()


func find_packed_client():
	client_version = ""
	var marker := client_base_dir.path_join("RESOLVED_VERSION")
	if FileAccess.file_exists(marker):
		var resolved := FileAccess.get_file_as_string(marker).strip_edges()
		if resolved.begins_with("v") and is_valid_client_version(resolved.substr(1)):
			client_version = resolved.substr(1)
		else:
			bk_log(LogLevel.ERROR, "Invalid Client RESOLVED_VERSION: %s" % resolved)
	else:
		client_version = pick_highest_version(list_client_versions(client_base_dir))
	client_bin_path = get_packed_client_binary_path()


func install_shared_client():
	# Run outside the project so a running executable does not block plugin updates.
	var target_dir := client_data_dir.path_join("bin").path_join("v" + client_version)
	var target := target_dir.path_join(client_bin_name)
	if FileAccess.file_exists(target) and FileAccess.get_sha256(target) == FileAccess.get_sha256(client_bin_path):
		client_bin_path = target
		return
	if DirAccess.make_dir_recursive_absolute(target_dir) == OK:
		# Stage per process before replacing an outdated shared copy.
		var temporary := target + "." + str(OS.get_process_id()) + ".tmp"
		if DirAccess.copy_absolute(client_bin_path, temporary) == OK:
			if DirAccess.rename_absolute(temporary, target) == OK:
				client_bin_path = target
				return
			DirAccess.remove_absolute(temporary)
	bk_log(LogLevel.WARNING, "Shared Client installation unavailable; running bundled executable")


static func is_valid_client_version(version: String) -> bool:
	var regex := RegEx.new()
	regex.compile("^" + CLIENT_API_VERSION.substr(1).replace(".", "\\.") + "\\.[0-9]+$")
	return regex.search(version) != null


static func is_compatible_client(found: String, required: String) -> bool:
	# Require the supported API series and at least the bundled patch.
	return is_valid_client_version(found) and not version_lt(found, required)


func init_gallery():
	gallery = gallery_scene.instantiate()
	gallery.plugin = self
	gallery.size_flags_vertical = Control.SIZE_EXPAND_FILL
	gallery.hide()
	EditorInterface.get_editor_main_screen().add_child(gallery)


func handle_tasks(tasks: Array) -> void:
	for task in tasks:
		match task.get("task_type"):
			"asset_download":
				log_download_task(task)
				if gallery:
					gallery.handle_task(task)
			"search", "thumbnail_download":
				if gallery:
					gallery.handle_task(task)
			"login", "oauth2/logout", "profiles/get_user_profile", "profiles/fetch_gravatar_image":
				auth.handle_task(task)
			"categories_update":
				if task.get("status") == "finished" and task.get("result") is Array:
					categories = task["result"]
					if gallery:
						gallery.on_categories_changed()
	if gallery:
		var reported := {}
		for task in tasks:
			reported[task.get("task_id", "")] = true
		gallery.drop_vanished_downloads(reported)


# Failed downloads from Send to Godot on blendkit.com show only here.
func log_download_task(task: Dictionary) -> void:
	match task.get("status"):
		"finished":
			var path := GalleryApi.unstaged_path(GalleryApi.task_file_path(task))
			bk_log(LogLevel.INFO, "Downloaded %s" % ProjectSettings.localize_path(path))
		"error":
			bk_log(LogLevel.WARNING, "Download failed: %s" % task.get("message", ""))
		"cancelled":
			bk_log(LogLevel.INFO, "Download cancelled")


## Read once, as it's sent with every Client request.
func get_addon_version() -> String:
	if addon_version.is_empty():
		var config := ConfigFile.new()
		var err := config.load("res://addons/blendkit/plugin.cfg")
		addon_version = str(config.get_value("plugin", "version", "unknown")) if err == OK else "unknown"
	return addon_version


func get_godot_version() -> String:
	var info := Engine.get_version_info()
	return "%d.%d.%d" % [info.major, info.minor, info.patch]


func client_url(endpoint: String) -> String:
	return "http://127.0.0.1:%s/%s/%s" % [port, CLIENT_API_VERSION, endpoint]


## Fields most Client requests start with.
func client_data(api_key: String = "") -> Dictionary:
	return {
		"app_id": OS.get_process_id(),
		"api_key": api_key,
		"addon_version": get_addon_version(),
		"platform_version": OS.get_name(),
	}


func get_packed_client_binary_path():
	var bin_path = client_base_dir.path_join("v" + client_version).path_join(client_bin_name)
	return ProjectSettings.globalize_path(bin_path)


func get_client_log_path(log_port: String) -> String:
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
