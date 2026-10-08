@tool
extends VBoxContainer
## One search result: thumbnail button, title, author and a footer with the
## plan badge and quality rating. The thumbnail shows download progress along
## its bottom edge and a downloaded or failed icon in its corner.

signal selected(asset: Dictionary)

const GalleryApi = preload("res://addons/blendkit/ui/gallery/gallery_api.gd")
const THUMB_SIZE := 160
const DOWNLOAD_BAR_HEIGHT := 4
const ACTIVE_DOWNLOAD := ["posting", "created", "progress"]

const TYPE_ICONS := {
	"model": "MeshInstance3D",
	"material": "StandardMaterial3D",
	"hdr": "WorldEnvironment",
	"scene": "PackedScene",
	"printable": "MeshInstance3D",
}

@onready var thumb_button: Button = $ThumbButton
@onready var downloaded_icon: TextureRect = $ThumbButton/DownloadedIcon
@onready var download_track: ColorRect = $ThumbButton/DownloadTrack
@onready var download_bar: ColorRect = $ThumbButton/DownloadTrack/DownloadBar
@onready var title_label: Label = $Title
@onready var author_label: Label = $Author
@onready var plan_label: Label = $Footer/Plan
@onready var rating_label: Label = $Footer/Rating

var asset: Dictionary = {}
var _has_thumbnail := false
## Shows the asset type icon instead of the thumbnail. Loading is usually
## near-instant, so the tile stays empty until the thumbnail fails.
var _thumbnail_failed := false
var _downloaded := false
var _tooltip := ""
## The gallery's download state of this asset, see gallery.downloads.
var _download: Dictionary = {}


func _ready() -> void:
	var edscale := EditorInterface.get_editor_scale()
	custom_minimum_size.x = THUMB_SIZE * edscale
	thumb_button.custom_minimum_size = Vector2.ONE * THUMB_SIZE * edscale
	downloaded_icon.custom_minimum_size = Vector2.ONE * 16 * edscale
	download_track.offset_top = -DOWNLOAD_BAR_HEIGHT * edscale
	thumb_button.pressed.connect(func(): selected.emit(asset))
	_update()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and is_node_ready():
		_update_theme()


func setup(new_asset: Dictionary) -> void:
	asset = new_asset
	if is_node_ready():
		_update()


func _update() -> void:
	var title := str(asset.get("displayName", asset.get("name", "")))
	title_label.text = title
	var author := GalleryApi.author_name(asset)
	author_label.text = author
	_tooltip = "%s\nby %s" % [title, author] if author else title
	var free: bool = asset.get("isFree") == true
	# Unknown for assets in the project not found on Blendkit.
	plan_label.text = "" if not asset.has("isFree") else "Free" if free else "Full Plan"
	var quality = asset.get("ratingsAverage", {})
	quality = quality.get("quality") if quality is Dictionary else null
	rating_label.text = "★ %.1f" % quality if quality is float or quality is int else ""
	_update_theme()


func _update_theme() -> void:
	var dim := get_theme_color("font_disabled_color", "Editor")
	author_label.add_theme_color_override("font_color", dim)
	rating_label.add_theme_color_override("font_color", dim)
	var free: bool = asset.get("isFree") == true
	plan_label.add_theme_color_override("font_color",
		get_theme_color("success_color" if free else "accent_color", "Editor"))
	download_bar.color = get_theme_color("accent_color", "Editor")
	_update_download()
	if not _has_thumbnail:
		thumb_button.expand_icon = false
		thumb_button.icon = get_theme_icon(TYPE_ICONS.get(asset.get("assetType", ""), "File"), "EditorIcons") \
			if _thumbnail_failed else null


func set_thumbnail(texture: Texture2D) -> void:
	if texture == null:
		set_thumbnail_failed()
		return
	_has_thumbnail = true
	thumb_button.expand_icon = true
	thumb_button.icon = texture


func set_thumbnail_failed() -> void:
	if _has_thumbnail or _thumbnail_failed:
		return
	_thumbnail_failed = true
	if is_node_ready():
		_update_theme()


## Falls back to the type icon if no thumbnail arrives within [param seconds].
func expect_thumbnail(seconds: float) -> void:
	get_tree().create_timer(seconds).timeout.connect(set_thumbnail_failed)


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
	var active := status in ACTIVE_DOWNLOAD
	download_track.visible = active
	download_bar.anchor_right = clampf(_download.get("progress", 0) / 100.0, 0.0, 1.0)
	var message: String = _download.get("message", "")
	thumb_button.tooltip_text = "%s\n%s" % [_tooltip, message] if active and message else _tooltip
	# The gallery marks cancelled downloads as errors with this message.
	var failed: bool = status == "error" and _download.get("message", "") != "Cancelled"
	downloaded_icon.visible = failed or (_downloaded and not active)
	if failed:
		downloaded_icon.texture = get_theme_icon("StatusError", "EditorIcons")
		downloaded_icon.tooltip_text = "Download failed: %s" % _download.get("message", "")
	else:
		downloaded_icon.texture = get_theme_icon("StatusSuccess", "EditorIcons")
		downloaded_icon.tooltip_text = "Downloaded"
