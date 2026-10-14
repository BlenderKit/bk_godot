@tool
extends AcceptDialog
## Asset details with a preview, description, key parameters and tags, and
## under them a file chooser with the action button. The action downloads,
## cancels the download, or opens the plans when a Full Plan asset needs
## them, with a login button next to it when logged out. The chooser marks
## the files already in the project, and for those the action shows the file
## instead. It isn't modal: clicking the editor outside closes it.

signal download_requested(asset: Dictionary, file_type: String)
signal cancel_requested(task_id: String)
signal tag_selected(tag: String)
signal author_selected(author_id: String, author_name: String)

const GalleryApi = preload("res://addons/blendkit/ui/gallery/gallery_api.gd")
const FileReveal = preload("res://addons/blendkit/ui/file_reveal.gd")
const ProjectAssets = preload("res://addons/blendkit/ui/gallery/project_assets.gd")
const Plans = preload("res://addons/blendkit/ui/plans.gd")
const Icons = preload("res://addons/blendkit/ui/icons.gd")
## Font Awesome icons, like on the web.
const SCORE_ICON_PATH := "res://addons/blendkit/ui/icons/trophy.svg"
const COMPLEXITY_ICON_PATH := "res://addons/blendkit/ui/icons/dumbbell.svg"
const PREVIEW_TYPES := ["full", "photo_full", "wire_full"]
const PREVIEW_LABELS := {"full": "Render", "photo_full": "Photo", "wire_full": "Wireframe"}
const LICENSE_LABELS := {"royalty_free": "Royalty Free", "cc_zero": "CC0"}
const MONTHS := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
## Presses right after the action turned into Cancel are a double click on
## Download, not a cancel.
const CANCEL_GUARD_MS := 500
## Taller descriptions scroll.
const DESCRIPTION_MAX_HEIGHT := 200

@onready var preview_frame: PanelContainer = %PreviewFrame
@onready var preview: TextureRect = %Preview
@onready var preview_strip: HBoxContainer = %PreviewStrip
@onready var right_pane: VBoxContainer = %Right
@onready var title_label: Label = %Title
@onready var heading: VBoxContainer = %Heading
@onready var type_label: Label = %AssetType
@onready var plan_label: Label = %Plan
@onready var description: RichTextLabel = %Description
@onready var params_grid: GridContainer = %Params
@onready var tags_row: HBoxContainer = %TagsRow
@onready var tags_key: Label = %TagsKey
@onready var tags_text: RichTextLabel = %Tags
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
	# the properties as wide as the preview, with the description under it
	right_pane.custom_minimum_size.x = preview.custom_minimum_size.x
	var title_size := get_theme_font_size("font_size", "Label") * 2
	title_label.add_theme_font_size_override("font_size", title_size)
	# the font leaves room above its capitals on every wrapped line too
	title_label.add_theme_constant_override("line_spacing", -int(title_size * 0.3))
	preview.resized.connect(_place_badge)
	var edscale := EditorInterface.get_editor_scale()
	# Only the mask's shape shows: the preview with rounded corners, like
	# the thumbnails of the gallery cards.
	var mask := StyleBoxFlat.new()
	mask.bg_color = Color.WHITE
	mask.set_corner_radius_all(int(8 * edscale))
	preview_frame.add_theme_stylebox_override("panel", mask)
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
			refresh_download(true))
	var dim := get_theme_color("font_disabled_color", "Editor")
	type_label.add_theme_color_override("font_color", dim)
	tags_key.add_theme_color_override("font_color", dim)
	# plain text like the web, not a panel
	description.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	description.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	description.add_theme_constant_override("line_separation", int(4 * EditorInterface.get_editor_scale()))
	# The tags are text with links, with the key's margins and color so they
	# share its baseline and look like the other values.
	var label_box := tags_key.get_theme_stylebox("normal")
	var tags_box := StyleBoxEmpty.new()
	for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		tags_box.set_content_margin(side, label_box.get_margin(side))
	tags_text.add_theme_stylebox_override("normal", tags_box)
	tags_text.add_theme_stylebox_override("focus", tags_box)
	# the key's color is overridden, the dialog has the plain label one
	tags_text.add_theme_color_override("default_color", get_theme_color("font_color", "Label"))
	tags_text.meta_clicked.connect(func(meta): tag_selected.emit(_tags()[int(meta)]))
	# a tooltip per tag, [hint] would underline them
	tags_text.meta_hover_started.connect(func(meta):
		tags_text.tooltip_text = "Search for \"%s\"" % _tags()[int(meta)]
		_fill_tags(int(meta)))
	tags_text.meta_hover_ended.connect(func(_meta):
		tags_text.tooltip_text = ""
		_fill_tags())
	# The type right above the title, also over the room the title font has
	# above its capitals, about a quarter of its size.
	heading.add_theme_constant_override("separation",
		-int(label_box.get_margin(SIDE_TOP) + label_box.get_margin(SIDE_BOTTOM) + title_size * 0.25))
	file_option.item_selected.connect(func(_i): refresh_download())
	exclusive = false
	# A separate window gets focus_entered on the editor window, an embedded
	# one (single window mode) only focus_exited on itself.
	get_tree().root.focus_entered.connect(_close_if_outside)
	focus_exited.connect(func(): _close_if_outside.call_deferred())


## Show the asset with the files in [param new_folder], by default the
## folder it's downloaded to, see _refresh_download().
func show_asset(new_asset: Dictionary, thumbnails: Dictionary, new_folder: String = "") -> void:
	asset = new_asset
	folder = new_folder if new_folder else ProjectAssets.asset_folder(gallery.plugin.absolute_download_path, asset)
	local_files = ProjectAssets.downloaded_files(folder, str(asset.get("id", "")))
	title = str(asset.get("displayName", asset.get("name", "Asset")))
	title_label.text = title
	var plan := Plans.asset_plan(asset)
	Plans.style_badge(plan_label, plan, Plans.ASSET_LABELS.get(plan, ""))
	type_label.text = GalleryApi.ASSET_TYPE_LABELS.get(asset.get("assetType", ""), "").trim_suffix("s")
	type_label.visible = not type_label.text.is_empty()
	description.text = str(asset.get("description", "")).strip_edges()
	description.visible = not description.text.is_empty()
	description.fit_content = true
	description.custom_minimum_size.y = 0
	_fill_params()
	_fill_tags()
	_fill_files(true)

	_textures.clear()
	_preview_type = ""
	preview.texture = null
	_rebuild_strip()
	for type in PREVIEW_TYPES:
		if thumbnails.has(type):
			on_thumbnail(type, GalleryApi.cached_texture(thumbnails[type]))
	if preview.texture == null and thumbnails.has("small"):
		preview.texture = GalleryApi.cached_texture(thumbnails["small"])
	_place_badge()

	refresh_download()
	_shown_frame = Engine.get_process_frames()
	# The wrapped text is as tall as it is at its width, which it only gets
	# once laid out, so give it that width first. Then the dialog opens as
	# big as its content, the panes go below the preview as needed.
	_set_text_widths()
	var max_height := DESCRIPTION_MAX_HEIGHT * EditorInterface.get_editor_scale()
	if description.get_content_height() > max_height:
		description.fit_content = false
		description.custom_minimum_size.y = max_height
	# A zero size keeps the current one, so start from the minimum.
	reset_size()
	popup_centered_clamped(Vector2i.ZERO, 0.9)
	await get_tree().process_frame
	if visible:
		# Enter acts like on the OK button the dialog hides. Logging in comes
		# first, an account may have Full Plan already.
		if _login_button.visible:
			_login_button.grab_focus()
		elif not action_button.disabled:
			action_button.grab_focus()


## The widths the panes give the wrapped text, before they are laid out.
## Also to the boxes around it, which would lay it out at their old width
## first.
func _set_text_widths() -> void:
	var pane := preview.custom_minimum_size.x
	var panes := right_pane.get_parent() as Container
	var content_width := pane * 2 + panes.get_theme_constant("separation")
	for box: Control in [panes.get_parent(), panes]:
		box.size.x = content_width
	for box: Control in [description.get_parent(), right_pane, heading, tags_row]:
		box.size.x = pane
	_set_text_width(title_label, pane)
	_set_text_width(description, pane)
	_set_text_width(tags_text, pane - tags_key.get_combined_minimum_size().x - tags_row.get_theme_constant("separation"))
	_set_text_width(note_label, content_width)


## Measures [param control] again at [param width] only when asked, and
## drops the height it had at the old width, which would grow the dialog.
func _set_text_width(control: Control, width: float) -> void:
	control.size.x = width
	control.update_minimum_size()
	control.size.y = 0


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


## The properties in rows like on the web: the author, ratings, size and
## parameters, then license and date.
func _fill_params() -> void:
	for child in params_grid.get_children():
		params_grid.remove_child(child)
		child.queue_free()
	var rows: Array = []
	var counts = asset.get("ratingsCount", {})
	if counts is Dictionary and counts.get("quality"):
		var edscale := EditorInterface.get_editor_scale()
		rows.append(["Score", "%.1f" % float(asset.get("score", 0)),
			"Asset score = average quality × median complexity × 10",
			Icons.render_svg(SCORE_ICON_PATH, edscale, true)])
		var average = asset.get("ratingsAverage", {})
		if average is Dictionary and average.get("quality") != null:
			rows.append(["Quality", "%.1f" % float(average.quality), "",
				get_theme_icon("Favorites", "EditorIcons")])
		var median = asset.get("ratingsMedian", {})
		if median is Dictionary and median.get("workingHours") != null:
			rows.append(["Complexity", "%.1f" % float(median.workingHours), "",
				Icons.render_svg(COMPLEXITY_ICON_PATH, edscale, true)])
	if asset.get("filesSize"):
		rows.append(["File size", String.humanize_size(int(asset.filesSize))])
	var p = asset.get("dictParameters", {})
	if p is Dictionary:
		if p.get("faceCount"):
			rows.append(["Polygons", _thousands(int(p.faceCount))])
		if p.has("dimensionX") and p.has("dimensionY") and p.has("dimensionZ"):
			rows.append(["Dimensions", "%s × %s × %s m" % [_num(p.dimensionX), _num(p.dimensionY), _num(p.dimensionZ)]])
		if p.get("textureSizeMeters"):
			rows.append(["Texture size", "%s m" % _num(p.textureSizeMeters)])
		if p.get("resolutionMax"):
			rows.append(["Resolution", "%d px" % int(p.resolutionMax)])
		for key in ["animated", "rig", "procedural"]:
			if p.get(key) is bool and p[key]:
				rows.append([{"animated": "Animated", "rig": "Rigged", "procedural": "Procedural"}[key], "Yes"])
		if p.get("modelStyle"):
			rows.append(["Style", str(p.modelStyle).capitalize()])
	var license := str(asset.get("license", ""))
	if license:
		rows.append(["License", LICENSE_LABELS.get(license, license.replace("_", " ").capitalize())])
	var created := _date(str(asset.get("created", "")))
	if created:
		rows.append(["Created", created])
	var dim := get_theme_color("font_disabled_color", "Editor")
	var author := GalleryApi.author_name(asset)
	if author:
		var author_key := Label.new()
		author_key.text = "Author"
		author_key.add_theme_color_override("font_color", dim)
		params_grid.add_child(author_key)
		var author_label := Label.new()
		author_label.text = author
		var author_id := str(asset.get("author", {}).get("id", ""))
		if author_id:
			_make_link(author_label, "Search for assets by %s" % author,
				func(): author_selected.emit(author_id, author))
		params_grid.add_child(author_label)
	for row in rows:
		var key_label := Label.new()
		key_label.text = row[0]
		key_label.add_theme_color_override("font_color", dim)
		if row.size() > 2 and row[2]:
			key_label.tooltip_text = row[2]
			key_label.mouse_filter = Control.MOUSE_FILTER_STOP
		params_grid.add_child(key_label)
		var value_label := Label.new()
		value_label.text = row[1]
		if row.size() < 4 or row[3] == null:
			params_grid.add_child(value_label)
			continue
		# the value with its icon after it, like on the web
		var value_box := HBoxContainer.new()
		value_box.add_theme_constant_override("separation", int(3 * EditorInterface.get_editor_scale()
			- tags_key.get_theme_stylebox("normal").get_margin(SIDE_RIGHT)))
		value_box.add_child(value_label)
		var icon := TextureRect.new()
		icon.texture = row[3]
		icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		value_box.add_child(icon)
		params_grid.add_child(value_box)


## The tags as links separated by commas, the one at [param hovered]
## highlighted.
func _fill_tags(hovered := -1) -> void:
	var tags := _tags()
	tags_row.visible = not tags.is_empty()
	var hover := get_theme_color("accent_color", "Editor").to_html()
	var links := PackedStringArray()
	for i in tags.size():
		var tag := str(tags[i]).replace("[", "[lb]")
		var link := "[url=%d]%s[/url]" % [i, tag]
		links.append("[color=#%s]%s[/color]" % [hover, link] if i == hovered else link)
	tags_text.text = ", ".join(links)


func _tags() -> Array:
	var tags = asset.get("tags")
	return tags if tags is Array else []


## Make [param label] clickable, highlighted on hover, calling [param on_click].
func _make_link(label: Label, tooltip: String, on_click: Callable) -> void:
	var hover := get_theme_color("accent_color", "Editor")
	label.tooltip_text = tooltip
	label.mouse_filter = Control.MOUSE_FILTER_STOP
	label.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	label.mouse_entered.connect(func(): label.add_theme_color_override("font_color", hover))
	label.mouse_exited.connect(func(): label.remove_theme_color_override("font_color"))
	label.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.is_released():
			on_click.call())


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


## Update the buttons and note from the asset's download state, and the
## files when [param files_changed], e.g. once a download ended. Progress
## reports change neither.
func refresh_download(files_changed := false) -> void:
	if asset.is_empty():
		return
	if files_changed:
		_read_files()
	var login_focused := _login_button.has_focus()
	_refresh_download()
	note_label.visible = not note_label.text.is_empty()
	# logged in, the focus moves on to the action
	if login_focused and not _login_button.visible and not action_button.disabled:
		action_button.grab_focus()


## A finished download adds its file, and its folder if it's the first.
func _read_files() -> void:
	if folder.is_empty():
		folder = ProjectAssets.asset_folder(gallery.plugin.absolute_download_path, asset)
	var files := ProjectAssets.downloaded_files(folder, str(asset.get("id", "")))
	if files != local_files:
		local_files = files
		_fill_files(false)


func _refresh_download() -> void:
	action_button.disabled = false
	action_button.tooltip_text = ""
	note_label.text = ""
	note_label.remove_theme_color_override("font_color")
	Plans.style_button(action_button, "")
	_login_button.hide()
	_web_button.visible = not GalleryApi.base_id(asset).is_empty()

	var dl: Dictionary = gallery.get_download(GalleryApi.base_id(asset))
	var status: String = dl.get("status", "")
	if status == "converting":
		# can't be cancelled, the download is done
		_cancel_since = -1
		action_button.text = "Converting…"
		action_button.disabled = true
		note_label.text = str(dl.get("message", ""))
		return
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
				note_label.text = "Get Blendkit Full Plan to download any asset and support human artists ♥"
			else:
				note_label.text = "Log in with Blendkit Full Plan to download any asset and support human artists ♥"
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
		note_label.text = "No glTF for this asset, using the %s file." % GalleryApi.file_type_label(selected_file_type())


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


## "07 Oct 2026" from an ISO date like "2026-10-07T12:00:00", or "".
static func _date(iso: String) -> String:
	var parts := iso.left(10).split("-")
	if parts.size() != 3 or not parts[1].is_valid_int() or int(parts[1]) < 1 or int(parts[1]) > 12:
		return ""
	return "%s %s %s" % [parts[2], MONTHS[int(parts[1]) - 1], parts[0]]


static func _num(value) -> String:
	return String.num(float(value), 2)


static func _thousands(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = " " + s.right(3) + out
		s = s.left(s.length() - 3)
	return ("-" if n < 0 else "") + s + out
