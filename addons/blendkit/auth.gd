@tool
extends Node
## Optional Blendkit login, the same OAuth2 PKCE flow as the Blender add-on.
##
## The Client receives the browser redirect on /consumer/exchange/ and
## reports the tokens as a "login" task. It broadcasts login, token refresh
## and logout tasks to every connected app, so a login is shared with other
## Blendkit add-ons using the same Client.
##
## Tokens are kept per user outside any project, in the editor's data dir.

## UI state changed: login pending, profile or avatar arrived.
signal changed
## The account the searches run as changed: logged in, out or switched.
signal account_changed

const GalleryApi = preload("res://addons/blendkit/ui/gallery/gallery_api.gd")

## Baked into the Client, which redeems the code with it.
const OAUTH_CLIENT_ID = "IdFRwa3SGA8eMpzhRVFMg5Ts8sPK93xBjif93x0F"
## Refresh tokens this long before they expire, like the Blender add-on.
const REFRESH_RESERVE := 3 * 24 * 3600
## Give up waiting for the browser after this long.
const LOGIN_TIMEOUT := 180.0
## Retry a refresh the Client never answered after this long.
const REFRESH_RETRY_MS := 10 * 60 * 1000
const AUTH_FILE := "blendkit_auth.json"
const PKCE_CHARS := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

## Set by the plugin before adding the node to the tree.
var plugin: EditorPlugin

var access_token := ""
var refresh_token := ""
var expires_at := 0.0
## User part of /api/v1/me/, cached so the account shows before connecting.
var profile: Dictionary = {}
var avatar_path := ""
var login_pending := false
var login_error := ""

var _login_timer: Timer
var _refresh_started := -1


func _ready() -> void:
	_login_timer = Timer.new()
	_login_timer.one_shot = true
	_login_timer.wait_time = LOGIN_TIMEOUT
	_login_timer.timeout.connect(_on_login_timeout)
	add_child(_login_timer)
	_load()


func is_logged_in() -> bool:
	return not access_token.is_empty()


## Access token for searches and downloads, "" when anonymous. An expired
## token counts as anonymous until the refresh arrives, so searches keep
## working meanwhile.
func api_key() -> String:
	if not is_logged_in():
		return ""
	maybe_refresh()
	if expires_at > 0 and now() >= expires_at:
		return ""
	return access_token


## Called by the plugin when it connects to a Client.
func on_connected() -> void:
	if not is_logged_in():
		return
	maybe_refresh()
	fetch_profile()


# MARK: login and logout

func login(signup := false) -> void:
	if not _is_connected():
		login_error = "Blendkit Client is not connected."
		changed.emit()
		return
	var verifier := new_pkce_verifier()
	var state := Crypto.new().generate_random_bytes(16).hex_encode()
	login_pending = true
	login_error = ""
	changed.emit()
	var body := _minimal_data()
	body["code_verifier"] = verifier
	body["state"] = state
	var response := await GalleryApi.post_json(self, _client_url("oauth2/verification_data"), body)
	if not login_pending:
		return # cancelled meanwhile
	if not response.ok:
		_login_failed("Could not start login: %s" % response.error)
		return
	var url := authorize_url(plugin.SERVER, plugin.port, state, pkce_challenge(verifier), signup)
	plugin.bk_log(plugin.LogLevel.INFO, "Opening login page in the browser")
	OS.shell_open(url)
	_login_timer.start()


func cancel_login() -> void:
	if not login_pending:
		return
	login_pending = false
	_login_timer.stop()
	changed.emit()


## Forget the tokens and ask the Client to revoke them. The Client reports
## the logout to all connected add-ons, which log out too.
func logout() -> void:
	var old_access := access_token
	var old_refresh := refresh_token
	_clear()
	plugin.bk_log(plugin.LogLevel.INFO, "Logged out")
	if old_refresh.is_empty() or not _is_connected():
		return
	var body := _minimal_data(old_access)
	body["refresh_token"] = old_refresh
	var response := await GalleryApi.post_json(self, _client_url("oauth2/logout"), body)
	if not response.ok:
		plugin.bk_log(plugin.LogLevel.WARNING, "Could not revoke tokens: %s" % response.error)


func maybe_refresh() -> void:
	if refresh_token.is_empty() or not needs_refresh(expires_at, now()) or not _is_connected():
		return
	if _refresh_started >= 0 and Time.get_ticks_msec() - _refresh_started < REFRESH_RETRY_MS:
		return
	_refresh_started = Time.get_ticks_msec()
	var body := _minimal_data(access_token)
	body["refresh_token"] = refresh_token
	plugin.bk_log(plugin.LogLevel.VERBOSE, "Refreshing login tokens")
	var response := await GalleryApi.post_json(self, _client_url("refresh_token"), body)
	if not response.ok:
		_refresh_started = -1
		plugin.bk_log(plugin.LogLevel.WARNING, "Could not refresh login: %s" % response.error)


func fetch_profile() -> void:
	if not is_logged_in() or not _is_connected():
		return
	var response := await GalleryApi.post_json(self, _client_url("profiles/get_user_profile"), _minimal_data(api_key()))
	if not response.ok:
		plugin.bk_log(plugin.LogLevel.WARNING, "Could not request profile: %s" % response.error)


func _fetch_avatar() -> void:
	if profile.is_empty() or not _is_connected():
		return
	var body := _minimal_data()
	body["id"] = int(profile.get("id", 0))
	body["avatar128"] = str(profile.get("avatar128", "")) if profile.get("avatar128") else ""
	body["gravatarHash"] = str(profile.get("gravatarHash", "")) if profile.get("gravatarHash") else ""
	await GalleryApi.post_json(self, _client_url("profiles/download_gravatar_image"), body)


# MARK: tasks

func handle_task(task: Dictionary) -> void:
	var status: String = task.get("status", "")
	var result = task.get("result")
	match task.get("task_type"):
		"login":
			if status == "finished" and result is Dictionary and result.get("access_token"):
				_on_tokens(result)
			elif status == "error":
				_on_login_error(str(task.get("message", "")))
		"oauth2/logout":
			# Logged out from this or another add-on.
			if is_logged_in():
				plugin.bk_log(plugin.LogLevel.INFO, "Logged out: %s" % task.get("message", ""))
				_clear()
		"profiles/get_user_profile":
			if status == "finished" and result is Dictionary and result.get("user") is Dictionary:
				if not is_logged_in():
					return
				var old_id = profile.get("id")
				profile = result.user
				if old_id != profile.get("id"):
					avatar_path = ""
				_save()
				changed.emit()
				_fetch_avatar()
			elif status == "error":
				plugin.bk_log(plugin.LogLevel.WARNING, "Could not load profile: %s" % task.get("message", ""))
		"profiles/fetch_gravatar_image":
			if status == "finished" and result is Dictionary and result.get("gravatar_path"):
				var data = task.get("data")
				if data is Dictionary and int(data.get("id", -1)) != int(profile.get("id", -2)):
					return
				avatar_path = str(result.gravatar_path)
				_save()
				changed.emit()


func _on_tokens(result: Dictionary) -> void:
	var switched := access_token.is_empty() or login_pending
	var was_pending := login_pending
	access_token = str(result.access_token)
	refresh_token = str(result.get("refresh_token", ""))
	expires_at = now() + float(result.get("expires_in", 36000))
	_refresh_started = -1
	login_pending = false
	login_error = ""
	_login_timer.stop()
	if switched:
		# A fresh login, possibly a different user.
		profile = {}
		avatar_path = ""
	_save()
	plugin.bk_log(plugin.LogLevel.INFO, "Logged in" if was_pending else ("Login received from another Blendkit add-on" if switched else "Login refreshed"))
	changed.emit()
	if switched:
		account_changed.emit()
	fetch_profile()


## Login errors are broadcast to all add-ons and carry no token, so only
## act on our own login or refresh.
func _on_login_error(message: String) -> void:
	if login_pending:
		_login_failed(message)
		return
	if _refresh_started < 0:
		plugin.bk_log(plugin.LogLevel.VERBOSE, "Ignoring login error of another add-on: %s" % message)
		return
	_refresh_started = -1
	if is_rejected_refresh(message):
		plugin.bk_log(plugin.LogLevel.WARNING, "Login expired, logging out: %s" % message)
		_clear()
	else:
		plugin.bk_log(plugin.LogLevel.WARNING, "Could not refresh login: %s" % message)


func _login_failed(message: String) -> void:
	login_pending = false
	login_error = message
	_login_timer.stop()
	plugin.bk_log(plugin.LogLevel.WARNING, "Login failed: %s" % message)
	changed.emit()


func _on_login_timeout() -> void:
	if login_pending:
		_login_failed("Login timed out.")


func _clear() -> void:
	var had_account := is_logged_in()
	access_token = ""
	refresh_token = ""
	expires_at = 0.0
	profile = {}
	avatar_path = ""
	_refresh_started = -1
	_save()
	changed.emit()
	if had_account:
		account_changed.emit()


# MARK: storage

func _auth_path() -> String:
	return EditorInterface.get_editor_paths().get_data_dir().path_join(AUTH_FILE)


func _load() -> void:
	var path := _auth_path()
	if not FileAccess.file_exists(path):
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not data is Dictionary:
		return
	access_token = str(data.get("access_token", ""))
	refresh_token = str(data.get("refresh_token", ""))
	expires_at = float(data.get("expires_at", 0))
	profile = data.get("profile", {}) if data.get("profile") is Dictionary else {}
	avatar_path = str(data.get("avatar_path", ""))


func _save() -> void:
	var path := _auth_path()
	if not is_logged_in():
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
		return
	if not FileAccess.file_exists(path):
		# Restrict access before the tokens are written.
		var created := FileAccess.open(path, FileAccess.WRITE)
		if created == null:
			plugin.bk_log(plugin.LogLevel.WARNING, "Could not save login to %s" % path)
			return
		created.close()
		if not OS.has_feature("windows"):
			FileAccess.set_unix_permissions(path, FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		plugin.bk_log(plugin.LogLevel.WARNING, "Could not save login to %s" % path)
		return
	file.store_string(JSON.stringify({
		"access_token": access_token,
		"refresh_token": refresh_token,
		"expires_at": expires_at,
		"profile": profile,
		"avatar_path": avatar_path,
	}, "\t"))


# MARK: helpers

func _is_connected() -> bool:
	return plugin != null and plugin.state == plugin.State.CONNECTED


func _client_url(endpoint: String) -> String:
	return GalleryApi.client_url(plugin.port, plugin.CLIENT_API_VERSION, endpoint)


func _minimal_data(key: String = "") -> Dictionary:
	return {
		"app_id": OS.get_process_id(),
		"api_key": key,
		"addon_version": plugin.get_addon_version(),
		"platform_version": OS.get_name(),
	}


static func now() -> float:
	return Time.get_unix_time_from_system()


static func needs_refresh(token_expires_at: float, time_now: float) -> bool:
	return time_now + REFRESH_RESERVE >= token_expires_at


## A refresh the server refused can't recover, unlike a network error.
static func is_rejected_refresh(message: String) -> bool:
	return message.to_lower().contains("refresh") and (message.contains("400") or message.contains("401"))


static func new_pkce_verifier() -> String:
	var verifier := ""
	for b in Crypto.new().generate_random_bytes(128):
		verifier += PKCE_CHARS[b % PKCE_CHARS.length()]
	return verifier


static func pkce_challenge(verifier: String) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(verifier.to_utf8_buffer())
	return Marshalls.raw_to_base64(ctx.finish()).replace("+", "-").replace("/", "_").replace("=", "")


## Login page URL. The browser returns to the Client on the given port,
## which must be one of the ports registered for the OAuth app.
static func authorize_url(server: String, client_port: String, state: String, challenge: String, signup: bool) -> String:
	var path := "/o/authorize?client_id=%s&response_type=code&state=%s&redirect_uri=http://localhost:%s/consumer/exchange/&code_challenge=%s&code_challenge_method=S256" % [
		OAUTH_CLIENT_ID, state, client_port, challenge]
	if signup:
		return "%s/accounts/register/?next=%s" % [server, path.uri_encode()]
	return server + path


## Short plan name for the account button, "" when unknown.
static func plan_label(user: Dictionary) -> String:
	var plan := str(user.get("currentPlanName", "")).strip_edges() if user.get("currentPlanName") else ""
	if user.get("hasFreePlan") == true or plan.to_lower() in ["free", "free plan"]:
		return "Free"
	if plan.is_empty():
		return ""
	return plan if plan.to_lower().ends_with("plan") else plan + " Plan"


static func display_name(user: Dictionary) -> String:
	for key in ["fullName", "username", "email"]:
		var value := str(user.get(key, "")).strip_edges() if user.get(key) else ""
		if not value.is_empty():
			return value
	return ""
