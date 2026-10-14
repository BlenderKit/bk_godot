@tool
extends Button
## One search result, a card like on blendkit.com: the square thumbnail with
## the plan badge in its bottom right corner and the asset name below. The
## thumbnail shows download progress along its bottom edge and a downloaded
## or failed icon in its top right corner. The card has the editor theme's
## button colors with rounded corners; a border shows on hover and focus.

signal selected(asset: Dictionary)

const GalleryApi = preload("res://addons/blendkit/ui/gallery/gallery_api.gd")
const Plans = preload("res://addons/blendkit/ui/plans.gd")
## Narrowest card; the gallery widens the cards to fill each row.
const MIN_WIDTH := 200
## Space between cards, as on the web gallery.
const GAP := 16
## Pixel size of the "small" thumbnail. Wider cards show the "full" one.
const SMALL_THUMB_SIZE := 256
const CORNER_RADIUS := 8
const TITLE_PADDING := Vector2(10, 6)
const FRAME_WIDTH := 2
const DOWNLOAD_BAR_HEIGHT := 4
const STATES := ["normal", "hover", "pressed", "hover_pressed"]
## Thumbnails the cards decode per frame, so a page of results or a large
## project shows its tiles without a hitch.
const THUMBNAILS_PER_FRAME := 8

const TYPE_ICONS := {
	"model": "MeshInstance3D",
	"material": "StandardMaterial3D",
	"hdr": "WorldEnvironment",
	"scene": "PackedScene",
	"printable": "MeshInstance3D",
}

@onready var thumb_clip: Panel = $ThumbClip
@onready var thumb: TextureRect = $ThumbClip/Thumb
@onready var downloaded_icon: TextureRect = $ThumbClip/Thumb/DownloadedIcon
@onready var download_track: ColorRect = $ThumbClip/Thumb/DownloadTrack
@onready var download_bar: ColorRect = $ThumbClip/Thumb/DownloadTrack/DownloadBar
@onready var title_label: Label = $Title
@onready var plan_label: Label = $ThumbClip/Thumb/Plan
@onready var frame: Panel = $Frame

var asset: Dictionary = {}
## Thumbnail type ("small" or "full") -> image path. Only the one the card
## shows is decoded, see _update_thumbnail().
var _thumbnails: Dictionary = {}
## Path of the thumbnail shown.
var _shown := ""
## Cards far from the view show no thumbnail, see set_near_view().
var _near_view := true
## Shows the asset type icon instead of the thumbnail. Loading is usually
## near-instant, so the tile stays empty until the thumbnail fails.
var _thumbnail_failed := false
var _downloaded := false
var _tooltip := ""
## The gallery's download state of this asset, see gallery.downloads.
var _download: Dictionary = {}
var _width := 0.0
var _hovered := false
## Adding the theme overrides notifies a theme change; ignore those.
var _updating_theme := false
## The StyleBoxes all cards share, built once per editor theme, see
## _shared_styles().
static var _styles: Dictionary = {}
## Cards waiting to decode their thumbnail, in order, see _decode_queued().
static var _decode_queue: Dictionary = {}
static var _decoding := false


func _ready() -> void:
	var edscale := EditorInterface.get_editor_scale()
	if _width == 0.0:
		_width = MIN_WIDTH * edscale
	downloaded_icon.custom_minimum_size = Vector2.ONE * 16 * edscale
	download_track.offset_top = -DOWNLOAD_BAR_HEIGHT * edscale
	pressed.connect(func(): selected.emit(asset))
	mouse_entered.connect(_set_hovered.bind(true))
	mouse_exited.connect(_set_hovered.bind(false))
	focus_entered.connect(_update_frame)
	focus_exited.connect(_update_frame)
	thumb.resized.connect(Plans.place_badge.bind(plan_label))
	_apply_theme()


func _notification(what: int) -> void:
	if not is_node_ready():
		return
	match what:
		NOTIFICATION_THEME_CHANGED:
			if not _updating_theme:
				_apply_theme()
		NOTIFICATION_RESIZED:
			_layout()


func setup(new_asset: Dictionary) -> void:
	asset = new_asset
	if is_node_ready():
		_update()


## The gallery's card width, the same for all cards of a grid.
func set_width(width: float) -> void:
	_width = width
	if is_node_ready():
		_update_size()


func _update() -> void:
	var title := str(asset.get("displayName", asset.get("name", "")))
	title_label.text = title
	var author := GalleryApi.author_name(asset)
	_tooltip = "%s\nby %s" % [title, author] if author else title
	var plan := Plans.asset_plan(asset)
	Plans.style_badge(plan_label, plan, Plans.ASSET_LABELS.get(plan, ""))
	Plans.place_badge(plan_label)
	_update_size()
	_update_download()
	_update_thumbnail()


## The theme's look, then the asset's.
func _apply_theme() -> void:
	_updating_theme = true
	var styles := _shared_styles()
	for state in STATES:
		add_theme_stylebox_override(state, styles[state])
	add_theme_stylebox_override("focus", styles.focus)
	thumb_clip.add_theme_stylebox_override("panel", styles.mask)
	title_label.add_theme_stylebox_override("normal", styles.title)
	download_bar.color = get_theme_color("accent_color", "Editor")
	_update_frame()
	_update()
	_updating_theme = false


func _shared_styles() -> Dictionary:
	var edscale := EditorInterface.get_editor_scale()
	var bases := STATES.map(func(state): return get_theme_stylebox(state, "PanelBackgroundButton"))
	var key := "%s %s" % [edscale, bases.map(func(base): return base.get_instance_id())]
	if _styles.get("key") == key:
		return _styles
	_styles = {"key": key, "focus": StyleBoxEmpty.new()}
	var radius := int(CORNER_RADIUS * edscale)
	# The editor's PanelBackgroundButton look with rounded corners and no
	# margins, so the thumbnail reaches the card's edges.
	for i in STATES.size():
		var box: StyleBoxFlat = bases[i].duplicate() if bases[i] is StyleBoxFlat else StyleBoxFlat.new()
		box.set_corner_radius_all(radius)
		box.set_content_margin_all(0)
		_styles[STATES[i]] = box
	# Only the mask's shape shows: the thumbnail with rounded top corners.
	var mask := StyleBoxFlat.new()
	mask.bg_color = Color.WHITE
	mask.corner_radius_top_left = radius
	mask.corner_radius_top_right = radius
	_styles.mask = mask
	var title_box := StyleBoxEmpty.new()
	title_box.content_margin_left = TITLE_PADDING.x * edscale
	title_box.content_margin_right = TITLE_PADDING.x * edscale
	title_box.content_margin_top = TITLE_PADDING.y * edscale
	title_box.content_margin_bottom = TITLE_PADDING.y * edscale
	_styles.title = title_box
	return _styles


## The card is as tall as its square thumbnail and the name below.
func _update_size() -> void:
	custom_minimum_size = Vector2(_width, _width + title_label.get_combined_minimum_size().y)
	_layout()


func _layout() -> void:
	var width := size.x
	thumb_clip.position = Vector2.ZERO
	thumb_clip.size = Vector2(width, width)
	title_label.position = Vector2(0, width)
	title_label.size = Vector2(width, size.y - width)
	_update_thumbnail()


func _set_hovered(hovered: bool) -> void:
	_hovered = hovered
	_update_frame()


## The border goes over the thumbnail, which covers the card's own focus and
## hover look.
func _update_frame() -> void:
	frame.visible = has_focus() or _hovered
	if not frame.visible:
		return
	var box := StyleBoxFlat.new()
	box.draw_center = false
	box.set_corner_radius_all(int(CORNER_RADIUS * EditorInterface.get_editor_scale()))
	box.set_border_width_all(maxi(1, int(FRAME_WIDTH * EditorInterface.get_editor_scale())))
	box.border_color = get_theme_color("accent_color", "Editor") if has_focus() \
		else Color(get_theme_color("mono_color", "Editor"), 0.35)
	frame.add_theme_stylebox_override("panel", box)


## The image of a [param type] thumbnail ("small" or "full") arrived.
func set_thumbnail(path: String, type: String = "small") -> void:
	_thumbnails[type] = path
	if is_node_ready():
		_update_thumbnail()


## Cards far from the view let go of their thumbnail, so long search results
## don't keep them all decoded. Back near it, they decode it again, usually
## from GalleryApi.cached_texture().
func set_near_view(near: bool) -> void:
	if near == _near_view:
		return
	_near_view = near
	if not is_node_ready():
		return
	if near:
		_update_thumbnail()
	else:
		_decode_queue.erase(self)
		_shown = ""
		thumb.texture = null


## The thumbnail to show: the "full" one when the card is wider than the
## "small" one, except for HDRs, whose "full" thumbnail is a panorama.
func _wanted_thumbnail() -> String:
	var want_full: bool = size.x > SMALL_THUMB_SIZE and asset.get("assetType", "") != "hdr"
	if want_full and _thumbnails.has("full"):
		return _thumbnails.full
	return _thumbnails.get("small", _thumbnails.get("full", ""))


## The shown thumbnail stays until the wanted one is decoded, see
## _decode_queued().
func _update_thumbnail() -> void:
	if not _near_view:
		return
	var path := _wanted_thumbnail()
	if path == _shown and not path.is_empty():
		_decode_queue.erase(self)
	elif not path.is_empty():
		_decode_queue[self] = true
		if not _decoding:
			_decode_queued()
	else:
		_decode_queue.erase(self)
		_shown = ""
		thumb.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		thumb.texture = get_theme_icon(TYPE_ICONS.get(asset.get("assetType", ""), "File"), "EditorIcons") \
			if _thumbnail_failed else null


## Decode the queued cards' thumbnails a few per frame from the next one,
## in the order they were queued.
static func _decode_queued() -> void:
	_decoding = true
	var tree := Engine.get_main_loop() as SceneTree
	while not _decode_queue.is_empty():
		await tree.process_frame
		for item in _decode_queue.keys().slice(0, THUMBNAILS_PER_FRAME):
			_decode_queue.erase(item)
			if is_instance_valid(item) and item.is_inside_tree():
				item._decode_thumbnail()
	_decoding = false


func _decode_thumbnail() -> void:
	var path := _wanted_thumbnail()
	if path.is_empty() or path == _shown:
		return
	var texture := GalleryApi.cached_texture(path)
	if texture == null:
		for type in _thumbnails.keys():
			if _thumbnails[type] == path:
				_thumbnails.erase(type)
		if _thumbnails.is_empty():
			set_thumbnail_failed()
		else:
			_update_thumbnail()
		return
	_shown = path
	thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	thumb.texture = texture


func set_thumbnail_failed() -> void:
	if not _thumbnails.is_empty() or _thumbnail_failed:
		return
	_thumbnail_failed = true
	if is_node_ready():
		_update_thumbnail()


func set_downloaded(downloaded: bool) -> void:
	_downloaded = downloaded
	_update_download()


func set_download(download: Dictionary) -> void:
	_download = download
	_update_download()


func _update_download() -> void:
	if not is_node_ready():
		return
	var status: String = _download.get("status", "")
	var active := status in GalleryApi.ACTIVE_DOWNLOAD
	download_track.visible = active
	download_bar.anchor_right = clampf(_download.get("progress", 0) / 100.0, 0.0, 1.0)
	var message: String = _download.get("message", "")
	tooltip_text = "%s\n%s" % [_tooltip, message] if active and message else _tooltip
	var failed := status == "error"
	downloaded_icon.visible = failed or (_downloaded and not active)
	if failed:
		downloaded_icon.texture = get_theme_icon("StatusError", "EditorIcons")
		downloaded_icon.tooltip_text = "Download failed: %s" % _download.get("message", "")
	else:
		downloaded_icon.texture = get_theme_icon("StatusSuccess", "EditorIcons")
		downloaded_icon.tooltip_text = "Downloaded"
