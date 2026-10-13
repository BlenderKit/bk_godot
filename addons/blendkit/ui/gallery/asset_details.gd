@tool
extends AcceptDialog
## Asset details with a preview, description, key parameters and tags, and
## under them a file chooser with the action button. The action downloads,
## cancels the download, or opens the plans when a Full Plan asset needs
## them, with a login button next to it when logged out. The chooser marks
## the files already in the project, and for those the action shows the file
## instead. It isn't modal: clicking the
## editor outside closes it.

signal download_requested(asset: Dictionary, file_type: String)
signal cancel_requested(task_id: String)
signal tag_selected(tag: String)

const GalleryApi = preload("res://addons/blendkit/ui/gallery/gallery_api.gd")
const FileReveal = preload("res://addons/blendkit/ui/file_reveal.gd")
const ProjectAssets = preload("res://addons/blendkit/ui/gallery/project_assets.gd")
const Plans = preload("res://addons/blendkit/ui/plans.gd")
const PREVIEW_TYPES := ["full", "photo_full", "wire_full"]
const PREVIEW_LABELS := {"full": "Render", "photo_full": "Photo", "wire_full": "Wireframe"}
const LICENSE_LABELS := {"royalty_free": "Royalty Free", "cc_zero": "CC0"}
## Presses right after the action turned into Cancel are a double click on
## Download, not a cancel.
const CANCEL_GUARD_MS := 500

@onready var preview: TextureRect = %Preview
@onready var preview_strip: HBoxContainer = %PreviewStrip
@onready var title_label: Label = %Title
@onready var author_label: Label = %Author
@onready var info_label: Label = %Info
@onready var plan_label: Label = %Plan
@onready var description: RichTextLabel = %Description
@onready var params_grid: GridContainer = %Params
@onready var tags_row: HBoxContainer = %TagsRow
@onready var tags_key: Label = %TagsKey
@onready var tags_flow: HFlowContainer = %Tags
@onready var note_label: Label = %Note
@onready var file_option: OptionButton = %FileOption
@onready var action_button: Button = %ActionButton
@onready var _web_button: Button = %WebButton
@onready var _login_button: Button = %LogIn

## Set by the gallery, used to read download state and the download settings.
var gallery: Node
var asset: Dictionary = {}
## The asset's folder in the download directory.
var folder := ""
## The files downloaded to the folder: fileType -> path.
var local_files: Dictionary = {}
var _textures: Dictionary = {}
var _preview_type := ""
var _shown_frame := -1
## When the action turned into Cancel, or -1.
var _cancel_since := -1
## When the downloaded files stop waiting for the FileSystem dock: path -> msec.
var _index_deadlines: Dictionary = {}


func _ready() -> void:
	preview.custom_minimum_size = Vector2.ONE * 400 * EditorInterface.get_editor_scale()
	preview.resized.connect(_place_badge)
	# clicking outside closes it, the own footer centers the action
	get_ok_button().hide()
	# no space for the empty button row under the footer
	add_theme_constant_override("buttons_separation", 0)
	action_button.pressed.connect(_on_action)
	_login_button.pressed.connect(_on_login)
	_web_button.pressed.connect(func(): OS.shell_open(GalleryApi.web_url(gallery.plugin.SERVER, asset)))
	# a downloaded file can be shown once the dock lists it
	EditorInterface.get_resource_filesystem().filesystem_changed.connect(func():
		if visible:
			refresh_download())
	var dim := get_theme_color("font_disabled_color", "Editor")
	info_label.add_theme_color_override("font_color", dim)
	tags_key.add_theme_color_override("font_color", dim)
	# The tags are labels like the key, so they share its margins and
	# baseline, with the rows overlapping by the vertical margins.
	var label_box := tags_key.get_theme_stylebox("normal")
	tags_flow.add_theme_constant_override("v_separation",
		-int(label_box.get_margin(SIDE_TOP) + label_box.get_margin(SIDE_BOTTOM)))
	tags_flow.add_theme_constant_override("h_separation",
		int(12 * EditorInterface.get_editor_scale() - label_box.get_margin(SIDE_LEFT) - label_box.get_margin(SIDE_RIGHT)))
	# no gap between the author and the rest of the byline
	var author_box: StyleBox = label_box.duplicate()
	author_box.content_margin_right = 0
	author_label.add_theme_stylebox_override("normal", author_box)
	var info_box: StyleBox = label_box.duplicate()
	info_box.content_margin_left = 0
	info_label.add_theme_stylebox_override("normal", info_box)
	# the tags line up with the parameter values
	params_grid.sort_children.connect(func():
		tags_key.custom_minimum_size.x = params_grid.get_child(0).size.x if params_grid.get_child_count() else 0.0)
	file_option.item_selected.connect(func(_i): refresh_download())
	exclusive = false
	# A separate window gets focus_entered on the editor window, an embedded
	# one (single window mode) only focus_exited on itself.
	get_tree().root.focus_entered.connect(_close_if_outside)
	focus_exited.connect(func(): _close_if_outside.call_deferred())


## Show the asset with the files in [param new_folder], by default the
## folder it downloads to.
func show_asset(new_asset: Dictionary, thumbnails: Dictionary, new_folder: String = "") -> void:
	asset = new_asset
	folder = new_folder if new_folder else GalleryApi.asset_download_dir(gallery.plugin.absolute_download_path, asset)
	local_files = ProjectAssets.downloaded_files(folder)
	title = str(asset.get("displayName", asset.get("name", "Asset")))
	title_label.text = title
	title_label.tooltip_text = title
	var author := GalleryApi.author_name(asset)
	author_label.text = "by " + author if author else ""
	var license := str(asset.get("license", ""))
	var plan := Plans.asset_plan(asset)
	Plans.style_badge(plan_label, plan, Plans.ASSET_LABELS.get(plan, ""))
	var info := PackedStringArray([
		LICENSE_LABELS.get(license, license.replace("_", " ").capitalize()),
		GalleryApi.ASSET_TYPE_LABELS.get(asset.get("assetType", ""), "").trim_suffix("s"),
	])
	info_label.text = " · ".join(PackedStringArray(Array(info).filter(func(s): return not s.is_empty())))
	if author and info_label.text:
		info_label.text = " · " + info_label.text
	info_label.tooltip_text = info_label.text.trim_prefix(" · ")
	description.text = str(asset.get("description", "")).strip_edges()
	_fill_params()
	_fill_tags()
	_fill_files(true)

	_textures.clear()
	_preview_type = ""
	preview.texture = null
	_rebuild_strip()
	for type in PREVIEW_TYPES:
		if thumbnails.has(type):
			on_thumbnail(type, GalleryApi.load_texture(thumbnails[type]))
	if preview.texture == null and thumbnails.has("small"):
		preview.texture = GalleryApi.cached_texture(thumbnails["small"])
	_place_badge()

	refresh_download()
	var edscale := EditorInterface.get_editor_scale()
	_shown_frame = Engine.get_process_frames()
	# As tall as the content, the description takes what's left and scrolls.
	# A zero height keeps the current one, so start from the minimum.
	reset_size()
	popup_centered_clamped(Vector2i(Vector2(960, 0) * edscale), 0.9)
	# The tags wrap only once laid out at their width, and until then the
	# dialog grows for one tag per row.
	await get_tree().process_frame
	if visible:
		size.y = 0
		# Enter acts like on the OK button the dialog hides. Logging in comes
		# first, an account may have Full Plan already.
		if _login_button.visible:
			_login_button.grab_focus()
		elif not action_button.disabled:
			action_button.grab_focus()


## Close when the focus went to the editor, not when it went to another app
## (a browser opened by the buttons) or to the dialog's own popups.
func _close_if_outside() -> void:
	if not is_inside_tree() or not visible or has_focus() or _shown_frame == Engine.get_process_frames():
		return
	if not get_tree().root.has_focus():
		return
	for window in find_children("*", "Window", true, false):
		if window.visible:
			return
	hide()


func on_thumbnail(type: String, texture: Texture2D) -> void:
	if texture == null or not type in PREVIEW_TYPES:
		return
	_textures[type] = texture
	_rebuild_strip()
	# the render is the main preview, others are only offered in the strip
	if _preview_type.is_empty() or type == "full":
		_set_preview(type)


func _set_preview(type: String) -> void:
	_preview_type = type
	preview.texture = _textures[type]
	_place_badge()
	for button in preview_strip.get_children():
		button.set_pressed_no_signal(button.get_meta("type") == type)


## The plan badge in the corner of the shown preview.
func _place_badge() -> void:
	Plans.place_badge(plan_label, preview.texture.get_size() if preview.texture else Vector2.ZERO)


func _rebuild_strip() -> void:
	for child in preview_strip.get_children():
		preview_strip.remove_child(child)
		child.queue_free()
	if _textures.size() < 2:
		return
	var edscale := EditorInterface.get_editor_scale()
	for type in PREVIEW_TYPES:
		if not _textures.has(type):
			continue
		var button := Button.new()
		button.set_meta("type", type)
		button.custom_minimum_size = Vector2.ONE * 64 * edscale
		button.expand_icon = true
		button.icon = _textures[type]
		button.tooltip_text = PREVIEW_LABELS[type]
		button.toggle_mode = true
		button.button_pressed = type == _preview_type
		button.pressed.connect(_set_preview.bind(type))
		preview_strip.add_child(button)


func _fill_params() -> void:
	for child in params_grid.get_children():
		params_grid.remove_child(child)
		child.queue_free()
	var p = asset.get("dictParameters", {})
	if not p is Dictionary:
		return
	var rows: Array = []
	if p.get("faceCount"):
		rows.append(["Polygons", _thousands(int(p.faceCount))])
	if p.has("dimensionX") and p.has("dimensionY") and p.has("dimensionZ"):
		rows.append(["Dimensions", "%s × %s × %s m" % [_num(p.dimensionX), _num(p.dimensionY), _num(p.dimensionZ)]])
	if p.get("textureResolutionMax"):
		rows.append(["Max texture", "%d px" % int(p.textureResolutionMax)])
	if p.get("textureSizeMeters"):
		rows.append(["Texture size", "%s m" % _num(p.textureSizeMeters)])
	if p.get("resolutionMax"):
		rows.append(["Resolution", "%d px" % int(p.resolutionMax)])
	for key in ["animated", "rig", "procedural"]:
		if p.has(key) and p[key] is bool:
			rows.append([{"animated": "Animated", "rig": "Rigged", "procedural": "Procedural"}[key], "Yes" if p[key] else "No"])
	if p.get("modelStyle"):
		rows.append(["Style", str(p.modelStyle).capitalize()])
	var dim := get_theme_color("font_disabled_color", "Editor")
	for row in rows:
		var key_label := Label.new()
		key_label.text = row[0]
		key_label.add_theme_color_override("font_color", dim)
		params_grid.add_child(key_label)
		var value_label := Label.new()
		value_label.text = row[1]
		params_grid.add_child(value_label)


func _fill_tags() -> void:
	for child in tags_flow.get_children():
		tags_flow.remove_child(child)
		child.queue_free()
	var tags: Array = asset.get("tags", [])
	tags_row.visible = not tags.is_empty()
	var hover := get_theme_color("accent_color", "Editor")
	for tag in tags:
		var label := Label.new()
		label.text = str(tag)
		label.tooltip_text = "Search for \"%s\"" % tag
		label.mouse_filter = Control.MOUSE_FILTER_STOP
		label.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		label.mouse_entered.connect(func(): label.add_theme_color_override("font_color", hover))
		label.mouse_exited.connect(func(): label.remove_theme_color_override("font_color"))
		label.gui_input.connect(func(event: InputEvent):
			if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.is_released():
				tag_selected.emit(str(tag)))
		tags_flow.add_child(label)


## List the files to download and the downloaded ones, marked. Keeps the
## selection unless [param reset], which selects the preferred file.
func _fill_files(reset: bool) -> void:
	var selected := "" if reset else selected_file_type()
	if selected.is_empty():
		selected = _preferred_file_type()
	file_option.clear()
	var downloadable := GalleryApi.downloadable_file_types(asset)
	var check := get_theme_icon("StatusSuccess", "EditorIcons")
	for entry in GalleryApi.FILE_TYPES:
		var file_type: String = entry[0]
		if local_files.has(file_type):
			file_option.add_icon_item(check, entry[1])
		elif file_type in downloadable:
			file_option.add_item(entry[1])
		else:
			continue
		var index := file_option.item_count - 1
		file_option.set_item_metadata(index, file_type)
		if local_files.has(file_type):
			file_option.set_item_tooltip(index, "Downloaded")
		if file_type == selected:
			file_option.select(index)
	if file_option.selected < 0 and file_option.item_count > 0:
		file_option.select(0)
	file_option.disabled = file_option.item_count == 0


## The file the settings prefer among the downloaded ones, or among all.
func _preferred_file_type() -> String:
	var choice := asset
	if not local_files.is_empty():
		choice = {"assetType": asset.get("assetType", ""),
			"files": local_files.keys().map(func(t): return {"fileType": t})}
	return GalleryApi.pick_file_type(choice, gallery.plugin.model_format, gallery.plugin.download_resolution())


## Show newer asset data, e.g. looked up for an asset from the project, with
## the same files selected.
func update_asset(new_asset: Dictionary) -> void:
	asset = new_asset
	_fill_files(false)
	refresh_download()


func selected_file_type() -> String:
	if file_option.selected < 0:
		return ""
	return str(file_option.get_item_metadata(file_option.selected))


## Update the buttons and note from the asset's download state.
func refresh_download() -> void:
	if asset.is_empty():
		return
	var login_focused := _login_button.has_focus()
	_refresh_download()
	note_label.visible = not note_label.text.is_empty()
	# logged in, the focus moves on to the action
	if login_focused and not _login_button.visible and not action_button.disabled:
		action_button.grab_focus()


func _refresh_download() -> void:
	# A finished download adds its file.
	var files := ProjectAssets.downloaded_files(folder)
	if files != local_files:
		local_files = files
		_fill_files(false)
	action_button.disabled = false
	action_button.tooltip_text = ""
	note_label.text = ""
	note_label.remove_theme_color_override("font_color")
	Plans.style_button(action_button, "")
	_login_button.hide()
	_web_button.visible = not GalleryApi.base_id(asset).is_empty()

	var dl: Dictionary = gallery.get_download(GalleryApi.base_id(asset))
	var status: String = dl.get("status", "")
	if status in GalleryApi.ACTIVE_DOWNLOAD and str(dl.get("task_id", "")):
		action_button.text = "Cancel Download (%d%%)" % int(dl.get("progress", 0))
		if _cancel_since < 0:
			_cancel_since = Time.get_ticks_msec()
		note_label.text = str(dl.get("message", ""))
		return
	_cancel_since = -1
	if status in GalleryApi.ACTIVE_DOWNLOAD:
		# can't be cancelled before the Client has the task
		action_button.text = "Downloading…"
		action_button.disabled = true
		note_label.text = str(dl.get("message", ""))
		return
	if local_files.has(selected_file_type()):
		var path: String = local_files[selected_file_type()]
		note_label.text = path.get_file()
		if _waits_for_index(path):
			action_button.text = "Importing…"
			action_button.disabled = true
			action_button.tooltip_text = "Waiting for the editor to import the file."
			return
		action_button.text = "Show File"
		action_button.tooltip_text = "Show the file in the FileSystem dock if Godot imports it, otherwise in the file manager."
		return
	action_button.text = "Download"
	if asset.get("canDownload") != true:
		var auth = gallery.plugin.auth
		if not auth.is_logged_in():
			_login_button.show()
			_login_button.text = "Cancel Login" if auth.login_pending else "Log In…"
		if _offers_full_plan():
			action_button.text = "Get Full Plan…"
			Plans.style_button(action_button, "full")
			action_button.tooltip_text = "See the Blendkit plans in the browser."
			if auth.is_logged_in():
				note_label.text = "Get Blendkit Full Plan to download and support human artists ♥"
			else:
				note_label.text = "Log in with Blendkit Full Plan to download and support human artists ♥"
		else:
			action_button.disabled = true
			var reason := GalleryApi.cant_download_message(asset).strip_edges()
			if reason and not reason.ends_with("."):
				reason += "."
			note_label.text = reason if reason else "This asset can't be downloaded here."
		return
	if file_option.item_count == 0:
		action_button.disabled = true
		note_label.text = "No downloadable file for this asset."
		return

	var same_file: bool = dl.get("file_type", "") == selected_file_type()
	if status == "error" and same_file:
		note_label.text = "Download failed: %s" % dl.get("message", "")
		note_label.add_theme_color_override("font_color", get_theme_color("error_color", "Editor"))
	elif status == "cancelled" and same_file:
		note_label.text = "Download cancelled."
	elif _gltf_unavailable():
		note_label.text = "No glTF for this asset, using %s." % GalleryApi.file_type_label(selected_file_type())


## A downloaded file the FileSystem dock will list but doesn't yet, until
## it does or it's waited for long enough.
func _waits_for_index(path: String) -> bool:
	if not FileReveal.is_pending(path):
		_index_deadlines.erase(path)
		return false
	if not _index_deadlines.has(path):
		_index_deadlines[path] = Time.get_ticks_msec() + FileReveal.INDEX_WAIT_MS
		get_tree().create_timer(FileReveal.INDEX_WAIT_MS / 1000.0).timeout.connect(func():
			if visible:
				refresh_download())
	return Time.get_ticks_msec() < _index_deadlines[path]


## glTF is the Model Format but the model has none, so a .blend is picked.
func _gltf_unavailable() -> bool:
	if asset.get("assetType", "") != "model" or gallery.plugin.model_format == "blend":
		return false
	var present := GalleryApi.file_types(asset)
	return not ("gltf_godot" in present or "gltf" in present)


## A Full Plan asset and an account that may not have Full Plan: logged
## out, or on the Free plan.
func _offers_full_plan() -> bool:
	var auth = gallery.plugin.auth
	return asset.get("isFree") != true and (not auth.is_logged_in() or Plans.user_plan(auth.profile) == "free")


func _on_action() -> void:
	var file_type := selected_file_type()
	var dl: Dictionary = gallery.get_download(GalleryApi.base_id(asset))
	if dl.get("status", "") in GalleryApi.ACTIVE_DOWNLOAD:
		if dl.get("task_id") and _cancel_since >= 0 and Time.get_ticks_msec() - _cancel_since >= CANCEL_GUARD_MS:
			cancel_requested.emit(dl.task_id)
		return
	if local_files.has(file_type):
		FileReveal.reveal(local_files[file_type])
		hide()
		return
	if asset.get("canDownload") != true:
		if _offers_full_plan():
			OS.shell_open(gallery.plugin.SERVER + "/plans/pricing/")
		return
	if not file_type.is_empty():
		download_requested.emit(asset, file_type)


func _on_login() -> void:
	var auth = gallery.plugin.auth
	if auth.login_pending:
		auth.cancel_login()
	else:
		auth.login()
	refresh_download()


static func _num(value) -> String:
	return String.num(float(value), 2)


static func _thousands(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = " " + s.right(3) + out
		s = s.left(s.length() - 3)
	return ("-" if n < 0 else "") + s + out
