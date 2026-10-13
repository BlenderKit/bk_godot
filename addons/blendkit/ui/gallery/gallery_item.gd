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
const MIN_WIDTH := 256
## Space between cards, as on the web gallery.
const GAP := 16
## Pixel size of the "small" thumbnail. Wider cards show the "full" one.
const SMALL_THUMB_SIZE := 256
const CORNER_RADIUS := 8
const TITLE_PADDING := Vector2(10, 6)
const FRAME_WIDTH := 2
const DOWNLOAD_BAR_HEIGHT := 4

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
## Thumbnail type ("small" or "full") -> texture.
var _thumbnails: Dictionary = {}
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
	_update()


func _notification(what: int) -> void:
	if not is_node_ready():
		return
	match what:
		NOTIFICATION_THEME_CHANGED:
			if not _updating_theme:
				_updating_theme = true
				_update_theme()
				_updating_theme = false
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
	_updating_theme = true
	_update_theme()
	_updating_theme = false


func _update_theme() -> void:
	var edscale := EditorInterface.get_editor_scale()
	var radius := int(CORNER_RADIUS * edscale)
	# The editor's PanelBackgroundButton look with rounded corners and no
	# margins, so the thumbnail reaches the card's edges.
	for state in ["normal", "hover", "pressed", "hover_pressed"]:
		var base: StyleBox = get_theme_stylebox(state, "PanelBackgroundButton")
		var box: StyleBoxFlat = base.duplicate() if base is StyleBoxFlat else StyleBoxFlat.new()
		box.set_corner_radius_all(radius)
		box.set_content_margin_all(0)
		add_theme_stylebox_override(state, box)
	add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	# Only the mask's shape shows: the thumbnail with rounded top corners.
	var mask := StyleBoxFlat.new()
	mask.bg_color = Color.WHITE
	mask.corner_radius_top_left = radius
	mask.corner_radius_top_right = radius
	thumb_clip.add_theme_stylebox_override("panel", mask)
	var title_box := StyleBoxEmpty.new()
	title_box.content_margin_left = TITLE_PADDING.x * edscale
	title_box.content_margin_right = TITLE_PADDING.x * edscale
	title_box.content_margin_top = TITLE_PADDING.y * edscale
	title_box.content_margin_bottom = TITLE_PADDING.y * edscale
	title_label.add_theme_stylebox_override("normal", title_box)
	var plan := Plans.asset_plan(asset)
	Plans.style_badge(plan_label, plan, Plans.ASSET_LABELS.get(plan, ""))
	Plans.place_badge(plan_label)
	download_bar.color = get_theme_color("accent_color", "Editor")
	_update_size()
	_update_frame()
	_update_download()
	_update_thumbnail()


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


## A [param type] thumbnail ("small" or "full") arrived; null if it failed.
func set_thumbnail(texture: Texture2D, type: String = "small") -> void:
	if texture == null:
		set_thumbnail_failed()
		return
	_thumbnails[type] = texture
	if is_node_ready():
		_update_thumbnail()


## Show the "full" thumbnail when the card is wider than the "small" one,
## except for HDRs, whose "full" thumbnail is a panorama.
func _update_thumbnail() -> void:
	var want_full: bool = size.x > SMALL_THUMB_SIZE and asset.get("assetType", "") != "hdr"
	var texture: Texture2D = _thumbnails.get("full") if want_full else null
	if texture == null:
		texture = _thumbnails.get("small", _thumbnails.get("full"))
	if texture:
		thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		thumb.texture = texture
	else:
		thumb.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		thumb.texture = get_theme_icon(TYPE_ICONS.get(asset.get("assetType", ""), "File"), "EditorIcons") \
			if _thumbnail_failed else null


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
