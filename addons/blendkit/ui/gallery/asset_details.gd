@tool
extends ConfirmationDialog
## Asset details with a preview, description, key parameters, tags and a
## file chooser. OK downloads, or opens the asset web page (or the plans for
## a Free plan account) when the user can't download it. For an asset
## already in the project, OK shows its file instead.

signal download_requested(asset: Dictionary, file_type: String)
signal cancel_requested(task_id: String)
signal tag_selected(tag: String)

const GalleryApi = preload("res://addons/blendkit/ui/gallery/gallery_api.gd")
const Auth = preload("res://addons/blendkit/auth.gd")
const FileReveal = preload("res://addons/blendkit/ui/file_reveal.gd")
const PREVIEW_TYPES := ["full", "photo_full", "wire_full"]
const PREVIEW_LABELS := {"full": "Render", "photo_full": "Photo", "wire_full": "Wireframe"}
const LICENSE_LABELS := {"royalty_free": "Royalty Free", "cc_zero": "CC0"}

@onready var preview: TextureRect = %Preview
@onready var preview_strip: HBoxContainer = %PreviewStrip
@onready var title_label: Label = %Title
@onready var author_label: Label = %Author
@onready var info_label: Label = %Info
@onready var description: RichTextLabel = %Description
@onready var params_grid: GridContainer = %Params
@onready var tags_flow: HFlowContainer = %Tags
@onready var file_option: OptionButton = %FileOption
@onready var note_label: Label = %Note

## Set by the gallery, used to read download state and the download settings.
var gallery: Node
var asset: Dictionary = {}
## The asset's file when it's shown from the project assets, else "".
var local_path := ""
var _textures: Dictionary = {}
var _preview_type := ""
var _web_button: Button
var _cancel_download_button: Button
var _login_button: Button


func _ready() -> void:
	dialog_hide_on_ok = false
	preview.custom_minimum_size = Vector2.ONE * 400 * EditorInterface.get_editor_scale()
	get_cancel_button().text = "Close"
	_web_button = add_button("View on blendkit.com", true, "web")
	_cancel_download_button = add_button("Cancel Download", true, "cancel_download")
	_cancel_download_button.hide()
	_login_button = add_button("Log In…", true, "login")
	_login_button.hide()
	confirmed.connect(_on_ok)
	custom_action.connect(_on_custom_action)
	file_option.item_selected.connect(func(_i): refresh_download())


func show_asset(new_asset: Dictionary, thumbnails: Dictionary, new_local_path: String = "") -> void:
	asset = new_asset
	local_path = new_local_path
	title = str(asset.get("displayName", asset.get("name", "Asset")))
	title_label.text = title
	title_label.tooltip_text = title
	var author := GalleryApi.author_name(asset)
	author_label.text = "by " + author if author else ""
	var license := str(asset.get("license", ""))
	var info := PackedStringArray([
		"" if not asset.has("isFree") else "Free" if asset.isFree == true else "Full Plan",
		LICENSE_LABELS.get(license, license.replace("_", " ").capitalize()),
		GalleryApi.ASSET_TYPE_LABELS.get(asset.get("assetType", ""), "").trim_suffix("s"),
	])
	info_label.text = " · ".join(PackedStringArray(Array(info).filter(func(s): return not s.is_empty())))
	description.text = str(asset.get("description", "")).strip_edges()
	_fill_params()
	_fill_tags()
	_fill_files()

	_textures.clear()
	_preview_type = ""
	preview.texture = null
	_rebuild_strip()
	for type in PREVIEW_TYPES:
		if thumbnails.has(type):
			on_thumbnail(type, GalleryApi.load_texture(thumbnails[type]))
	if preview.texture == null and thumbnails.has("small"):
		preview.texture = GalleryApi.load_texture(thumbnails["small"])

	refresh_download()
	var edscale := EditorInterface.get_editor_scale()
	popup_centered_clamped(Vector2i(Vector2(960, 600) * edscale), 0.9)


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
	for button in preview_strip.get_children():
		button.set_pressed_no_signal(button.get_meta("type") == type)


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
		child.queue_free()
	var p = asset.get("dictParameters", {})
	if not p is Dictionary:
		return
	var rows: Array = []
	if p.get("faceCount"):
		rows.append(["Faces", _thousands(int(p.faceCount))])
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
		child.queue_free()
	for tag in asset.get("tags", []):
		var button := Button.new()
		button.text = str(tag)
		button.flat = true
		button.tooltip_text = "Search for \"%s\"" % tag
		button.pressed.connect(func(): tag_selected.emit(str(tag)))
		tags_flow.add_child(button)


func _fill_files() -> void:
	file_option.clear()
	var preferred := GalleryApi.pick_file_type(asset, gallery.plugin.model_format, gallery.plugin.resolution)
	for file_type in GalleryApi.downloadable_file_types(asset):
		file_option.add_item(GalleryApi.file_type_label(file_type))
		file_option.set_item_metadata(file_option.item_count - 1, file_type)
		if file_type == preferred:
			file_option.select(file_option.item_count - 1)
	file_option.disabled = file_option.item_count == 0


func selected_file_type() -> String:
	if file_option.selected < 0:
		return ""
	return str(file_option.get_item_metadata(file_option.selected))


## Update the buttons and note from the asset's download state.
func refresh_download() -> void:
	if asset.is_empty():
		return
	var ok := get_ok_button()
	ok.disabled = false
	_cancel_download_button.hide()
	_login_button.hide()
	note_label.text = ""
	note_label.remove_theme_color_override("font_color")
	_web_button.visible = not GalleryApi.base_id(asset).is_empty()
	file_option.get_parent().visible = local_path.is_empty()

	if not local_path.is_empty():
		ok.text = "Show in FileSystem"
		note_label.text = "In the project at %s" % ProjectSettings.localize_path(local_path)
		return
	if asset.get("canDownload") != true:
		var auth = gallery.plugin.auth
		ok.text = "Get on blendkit.com"
		if not auth.is_logged_in():
			_login_button.show()
			_login_button.disabled = auth.login_pending
			if asset.get("isFree") == true:
				note_label.text = "Log in to download this asset here, or use Send to Godot on blendkit.com."
			else:
				note_label.text = "Full Plan asset. Log in with Full Plan to download it here, or use Send to Godot on blendkit.com."
			return
		var reason := GalleryApi.cant_download_message(asset).strip_edges()
		if reason and not reason.ends_with("."):
			reason += "."
		if _needs_full_plan():
			ok.text = "Get Full Plan"
			note_label.text = reason if reason else "This asset needs Full Plan."
		else:
			note_label.text = reason if reason else "This asset can't be downloaded here. Try Send to Godot on blendkit.com."
		return
	if file_option.item_count == 0:
		ok.text = "Download"
		ok.disabled = true
		note_label.text = "No downloadable file for this asset."
		return

	var dl: Dictionary = gallery.get_download(GalleryApi.base_id(asset))
	var status: String = dl.get("status", "")
	var same_file: bool = dl.get("file_type", "") == selected_file_type()
	if status in GalleryApi.ACTIVE_DOWNLOAD:
		ok.text = "Downloading %d %%" % int(dl.get("progress", 0))
		ok.disabled = true
		_cancel_download_button.visible = not str(dl.get("task_id", "")).is_empty()
		note_label.text = str(dl.get("message", ""))
	elif status == "finished" and same_file and not str(dl.get("file_path", "")).is_empty():
		ok.text = "Show in FileSystem"
		note_label.text = "Downloaded to %s" % ProjectSettings.localize_path(dl.file_path)
	else:
		ok.text = "Download"
		if status == "error":
			note_label.text = "Download failed: %s" % dl.get("message", "")
			note_label.add_theme_color_override("font_color", get_theme_color("error_color", "Editor"))
		elif status == "cancelled":
			note_label.text = "Download cancelled."
		elif gallery.is_downloaded(asset):
			note_label.text = "Already in the project; downloading again reuses the files on disk."
		elif _gltf_unavailable():
			note_label.text = "No glTF for this asset, using %s." % GalleryApi.file_type_label(selected_file_type())


## glTF is the Model Format but the model has none, so a .blend is picked.
func _gltf_unavailable() -> bool:
	if asset.get("assetType", "") != "model" or gallery.plugin.model_format == "blend":
		return false
	var present := GalleryApi.file_types(asset)
	return not ("gltf_godot" in present or "gltf" in present)


## A Full Plan asset and a logged-in account on the Free plan.
func _needs_full_plan() -> bool:
	var auth = gallery.plugin.auth
	return asset.get("isFree") != true and auth.is_logged_in() and Auth.plan_label(auth.profile) == "Free"


func _on_ok() -> void:
	if not local_path.is_empty():
		FileReveal.reveal(local_path)
		hide()
		return
	if asset.get("canDownload") != true:
		if _needs_full_plan():
			OS.shell_open(gallery.plugin.SERVER + "/plans/pricing")
		else:
			OS.shell_open(GalleryApi.web_url(gallery.plugin.SERVER, asset))
		return
	var dl: Dictionary = gallery.get_download(GalleryApi.base_id(asset))
	if dl.get("status") == "finished" and dl.get("file_type", "") == selected_file_type() and dl.get("file_path"):
		FileReveal.reveal(dl.file_path)
		hide()
		return
	var file_type := selected_file_type()
	if not file_type.is_empty():
		download_requested.emit(asset, file_type)


func _on_custom_action(action: StringName) -> void:
	match action:
		"web":
			OS.shell_open(GalleryApi.web_url(gallery.plugin.SERVER, asset))
		"login":
			gallery.plugin.auth.login()
			refresh_download()
		"cancel_download":
			var dl: Dictionary = gallery.get_download(GalleryApi.base_id(asset))
			if dl.get("task_id"):
				cancel_requested.emit(dl.task_id)


static func _num(value) -> String:
	return String.num(float(value), 2)


static func _thousands(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = " " + s.right(3) + out
		s = s.left(s.length() - 3)
	return ("-" if n < 0 else "") + s + out
