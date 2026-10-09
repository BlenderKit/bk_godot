@tool
extends Node
## Finds a running Blendkit Client or starts one, and polls its /godot/report
## endpoint, which brings the task reports. Requests that start tasks go to
## the Client directly, see client_url() and client_data().

## Entered CONNECTED.
signal connected
## Entered DISABLED or FAILED.
signal stopped
## The state changed, or a request failed or recovered.
signal changed
## Each /godot/report response with its tasks, also when there are none.
signal tasks_reported(tasks: Array)

const ClientBinary = preload("res://addons/blendkit/client_binary.gd")
const GalleryApi = preload("res://addons/blendkit/ui/gallery/gallery_api.gd")

const CLIENT_PORTS = ["62485", "65425", "55428", "49452", "35452", "25152", "5152", "1234"]
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
# Values of these keys never go to the Output, e.g. the tokens in login tasks.
const SECRET_KEYS = ["access_token", "refresh_token", "api_key", "code_verifier"]


enum State { DISABLED, EXPLORING, STARTING, CONNECTED, FAILED }

static func state_name(s: State) -> String:
	var name = State.find_key(s)
	return name if name != null else str(s)


static func http_status_name(status: int) -> String:
	return engine_enum_name("HTTPClient", "Status", status)


static func http_result_name(result: int) -> String:
	return engine_enum_name("HTTPRequest", "Result", result)


## Name of an engine enum value without its prefix, e.g. "CANT_CONNECT" for
## HTTPRequest.RESULT_CANT_CONNECT.
static func engine_enum_name(engine_class: String, enum_name: String, value: int) -> String:
	for constant in ClassDB.class_get_enum_constants(engine_class, enum_name):
		if ClassDB.class_get_integer_constant(engine_class, constant) == value:
			return constant.substr(constant.find("_") + 1)
	return str(value)


var plugin: EditorPlugin
var client: ClientBinary

var state: State = State.DISABLED
var fail_reason: String = ""
var port: String = CLIENT_PORTS[0]
var taken_ports: Array[String] = []
var failed_requests: int = 0
var connected_client_version: String = ""
# Poll faster while someone waits for task reports, see set_fast_poll().
var fast_poll := false
var request_start_time: int = 0
var request_start_frame: int = 0
var starting_since: int = 0
var http_request: HTTPRequest
var unsubscribe_http_request: HTTPRequest
var timer: Timer


# Set up here, as the plugin starts the connection before its children are ready.
func _init(owner_plugin: EditorPlugin) -> void:
	plugin = owner_plugin
	client = ClientBinary.new(plugin, get_script().resource_path.get_base_dir().path_join("client"))

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


func start() -> void:
	enter_state(State.EXPLORING)


func stop() -> void:
	enter_state(State.DISABLED)


func fail(reason: String) -> void:
	fail_reason = reason
	enter_state(State.FAILED)


func enter_state(new_state: State) -> void:
	# Centralized state transition code
	var prev_state := state
	state = new_state
	failed_requests = 0
	match new_state:
		State.DISABLED, State.FAILED:
			if prev_state == State.CONNECTED:
				send_unsubscribe()
			timer.stop()
			http_request.cancel_request()
			if new_state == State.FAILED:
				plugin.log_error("Client failed: %s. Please consider reporting this with your Output." % fail_reason)
			else:
				plugin.log_info("Disabled")
			stopped.emit()
		State.EXPLORING:
			port = CLIENT_PORTS[0]
			taken_ports.clear()
			timer.wait_time = WAIT_EXPLORING
			timer.start()
			plugin.log_info("Searching for running Client...")
		State.STARTING:
			starting_since = Time.get_ticks_msec()
			timer.wait_time = WAIT_STARTING
			timer.start()
			var error := client.launch(port, plugin.SERVER, get_client_log_path(port))
			if error:
				fail(error)
		State.CONNECTED:
			timer.wait_time = WAIT_OK
			timer.start()
			update_poll_rate()
			if connected_client_version:
				plugin.log_info("Connected to Client v%s on port %s" % [connected_client_version, port])
			else:
				plugin.log_info("Connected to Client on port %s" % port)
			connected.emit()

	changed.emit()


## A copy of the JSON value with the SECRET_KEYS values replaced.
static func redact(value: Variant) -> Variant:
	if value is Dictionary:
		var result := {}
		for key in value:
			result[key] = "<redacted>" if str(key) in SECRET_KEYS and value[key] else redact(value[key])
		return result
	if value is Array:
		return value.map(redact)
	return value


func is_client_connected() -> bool:
	return state == State.CONNECTED


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
			return "Connected"
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


func on_timer_timeout() -> void:
	if state in [State.FAILED, State.DISABLED]:
		plugin.log_warning("Timer fired in %s state - shouldn't happen" % state_name(state))
		return

	var http_client_status := http_request.get_http_client_status()
	var prev_request_failed := false
	if http_client_status != HTTPClient.STATUS_DISCONNECTED:
		plugin.log_trace("HTTP client: %s" % http_status_name(http_client_status))

	match http_client_status:
		HTTPClient.STATUS_CONNECTING:
			# Probably no-one listening on that port
			plugin.log_debug("CONNECTING for too long on port %s" % port)
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
					plugin.log_debug("Main loop suspended for %d ms (%d frames) - postponing request timeout" % [elapsed, frames_elapsed])
					return
				plugin.log_warning("Request timeout in %s after %d ms (%d frames)" % [http_status_name(http_client_status), elapsed, frames_elapsed])
				prev_request_failed = true
			else:
				plugin.log_debug("Waiting in %s (%d ms, %d frames)" % [http_status_name(http_client_status), elapsed, frames_elapsed])
				return
		HTTPClient.STATUS_DISCONNECTED:
			# Ready to request
			pass
		_:
			# Other states are unexpected errors
			prev_request_failed = true
			plugin.log_warning("HTTP client: %s" % http_status_name(http_client_status))

	if prev_request_failed:
		plugin.log_trace("HTTP request: cancelling request after client fail")
		http_request.cancel_request()
		request_failed()
		if state in [State.FAILED, State.DISABLED]:
			return

	if state == State.EXPLORING:
		plugin.log_verbose("Exploring port %s..." % port)

	var url := client_url("godot/report")
	var headers = ["Content-Type: application/json"]
	var data = {
		"name": "Godot",
		"appID": OS.get_process_id(),
		"version": get_godot_version(),
		"addonVersion": plugin.get_addon_version(),
		# Send to Godot downloads there, see GalleryApi.STAGING_DIR.
		"assetsPath": GalleryApi.staging_path(plugin.absolute_download_path),
		"projectName": ProjectSettings.get_setting("application/config/name"),
		"modelFormat": plugin.model_format,
		"resolution": plugin.resolution,
	}
	var json = JSON.stringify(data)
	request_start_time = Time.get_ticks_msec()
	request_start_frame = Engine.get_process_frames()
	plugin.log_trace("POST %s  %s" % [url, json])
	var error = http_request.request(url, headers, HTTPClient.METHOD_POST, json)
	if error != OK:
		plugin.log_error("Error sending request to %s, error=%s" % [url, error])
		http_request.cancel_request()
		request_failed()


func on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var elapsed := Time.get_ticks_msec() - request_start_time
	if result != OK:
		plugin.log_debug("Request %s, response_code=%d, state=%s, port=%s" % [http_result_name(result), response_code, state_name(state), port])
	if state in [State.DISABLED, State.FAILED]:
		plugin.log_warning("Ignoring stale request completion in %s state" % state_name(state))
		return

	var body_text: String = body.get_string_from_utf8()
	var data = JSON.parse_string(body_text) if response_code == 200 else null
	if plugin.log_level >= plugin.LogLevel.TRACE:
		var logged := JSON.stringify(redact(data)) if data is Dictionary else body_text
		plugin.log_trace("HTTP response (%d ms): %s" % [elapsed, logged])

	# Success - only a 200 with a valid JSON body counts as the Client
	if response_code == 200:
		if typeof(data) == TYPE_DICTIONARY:
			if state != State.CONNECTED:
				var found_version := str(data.get("client_version", ""))
				if not ClientBinary.is_compatible_client(found_version, client.version):
					var found_label := found_version if found_version else "(unknown)"
					plugin.log_info("Skipping Client v%s on port %s: incompatible with required v%s" % [found_label, port, client.version])
					mark_port_taken()
					request_failed()
					return
				connected_client_version = found_version
				enter_state(State.CONNECTED)
			elif failed_requests > 0:
				failed_requests = 0
				changed.emit()

			var msg = data.get("message", "")
			if msg:
				var level: int = plugin.client_message_log_level(int(data.get("message_level", 10)))
				plugin.bk_log(level, "Client: %s" % msg)
			var tasks = data.get("tasks", [])
			tasks_reported.emit(tasks if tasks is Array else [])
			return
		plugin.log_warning("Got 200 on port %s but body is not a valid JSON object - not the Client?" % port)

	if state == State.EXPLORING:
		# Any HTTP response means the port is occupied, including a different API series.
		if response_code > 0:
			mark_port_taken()
		plugin.log_verbose("Client not found on port %s" % port)
	elif response_code != 200:
		plugin.log_warning("Request on port %s failed (response_code=%d)" % [port, response_code])

	request_failed()


func mark_port_taken() -> void:
	if not taken_ports.has(port):
		taken_ports.append(port)


func request_failed() -> void:
	failed_requests += 1

	if state == State.EXPLORING:
		var port_index = CLIENT_PORTS.find(port)
		port_index += 1
		if port_index < CLIENT_PORTS.size():
			port = CLIENT_PORTS[port_index]
		else:
			port = choose_start_port()
			plugin.log_verbose("No running Client found")
			enter_state(State.STARTING)

	elif state == State.STARTING:
		var starting_elapsed := Time.get_ticks_msec() - starting_since
		if starting_elapsed >= STARTING_TIMEOUT:
			plugin.log_error("Failed to connect to Client on port %s after %s tries in %d ms." % [port, failed_requests, starting_elapsed])
			fail("connection timeout")
			return
		if failed_requests == STARTING_FAST_PROBES:
			plugin.log_verbose("Client not up after %d fast probes, slowing probes to %ss" % [STARTING_FAST_PROBES, WAIT_STARTING_SLOW])
			timer.wait_time = WAIT_STARTING_SLOW
			timer.start()
		changed.emit()

	elif state == State.CONNECTED:
		if failed_requests >= MAX_FAILED_REQUESTS:
			plugin.log_warning("Lost connection to Blendkit Client on port %s." % port)
			enter_state(State.EXPLORING)
			return
		changed.emit()

	else:
		plugin.log_error("Unexpected state: %s" % state_name(state))
		fail("unexpected state")


## Poll faster while waiting for search results, thumbnails or downloads,
## which all arrive through /godot/report.
func set_fast_poll(fast: bool) -> void:
	fast_poll = fast
	update_poll_rate()


func update_poll_rate() -> void:
	if state != State.CONNECTED:
		return
	var wait := WAIT_EXPLORING if fast_poll else WAIT_OK
	if is_equal_approx(timer.wait_time, wait):
		return
	timer.wait_time = wait
	if timer.time_left > wait:
		timer.start()


func choose_start_port() -> String:
	# The preferred port is the desired port, but discovery may have found an
	# unusable Client already running on it. In that case start on another known
	# port that we did not find occupied.
	var desired: String = plugin.preferred_port
	if not taken_ports.has(desired):
		return desired

	plugin.log_info("Desired port %s is occupied by an incompatible Client, choosing another port..." % desired)
	for candidate in CLIENT_PORTS:
		if not taken_ports.has(candidate):
			plugin.log_info("Selected port %s for the Client" % candidate)
			return candidate

	plugin.log_warning("All known ports are occupied, falling back to %s" % desired)
	return desired


func send_unsubscribe() -> void:
	var url := client_url("addons/unsubscribe")
	var headers = ["Content-Type: application/json"]
	var data = JSON.stringify({"app_id": OS.get_process_id()})
	plugin.log_info("Disconnecting from Client on port %s" % port)
	var error = unsubscribe_http_request.request(url, headers, HTTPClient.METHOD_POST, data)
	if error != OK:
		plugin.log_warning("Failed to send unsubscribe request: %s" % error)


func on_unsubscribe_completed(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	if result != OK or response_code != 200:
		plugin.log_warning("Unsubscribe request failed on port %s: result=%s, response_code=%d" % [port, http_result_name(result), response_code])
	else:
		plugin.log_verbose("Unsubscribed from Client on port %s" % port)


static func get_godot_version() -> String:
	var info := Engine.get_version_info()
	return "%d.%d.%d" % [info.major, info.minor, info.patch]


func client_url(endpoint: String) -> String:
	return "http://127.0.0.1:%s/%s/%s" % [port, ClientBinary.CLIENT_API_VERSION, endpoint]


## Fields most Client requests start with.
func client_data(api_key: String = "") -> Dictionary:
	return {
		"app_id": OS.get_process_id(),
		"api_key": api_key,
		"addon_version": plugin.get_addon_version(),
		"platform_version": OS.get_name(),
	}


static func get_client_log_path(log_port: String) -> String:
	var name := "default" if log_port == CLIENT_PORTS[0] else log_port
	return ClientBinary.get_client_data_dir().path_join("%s.log" % name)
