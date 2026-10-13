@tool
extends Control
## Points at a file selected in the FileSystem dock: the Blendkit logo
## shrinks onto it while fading in, then fades out. Purely cosmetic, so it
## frees itself quietly whenever the dock doesn't look as expected.
##
## Relies on the dock internals: one Tree (folders, and files in tree-only
## mode) and one ItemList (files in split mode), with each item's metadata
## holding its res:// path.

const Icons = preload("res://addons/blendkit/ui/icons.gd")

## Logo width when it lands on the file, in editor-scale pixels.
const END_SIZE := 40.0
## How many times bigger the logo starts.
const START_SCALE := 6.0
## How many times smaller it gets while fading out.
const FADE_OUT_SCALE := 0.25
## It shrinks onto the file while fading in, holds, and fades out shrinking.
const FADE_IN_TIME := 1.0
const HOLD_TIME := 0.2
const FADE_OUT_TIME := 1.0
## Frames to wait for the dock to scroll to the selection and lay it out.
const SETTLE_FRAMES := 3

var _path: String
var _dock: Control
var _logo: Texture2D
var _target := Vector2.ZERO
var _logo_size := 0.0


## Starts pointing at [param resource_path] once the dock selected it.
static func point_at(resource_path: String) -> void:
	var dock := EditorInterface.get_file_system_dock()
	if dock == null or not dock.is_inside_tree():
		return
	var pointer := new()
	pointer._path = resource_path
	pointer._dock = dock
	dock.get_window().add_child(pointer)


func _ready() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	texture_filter = TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	z_index = RenderingServer.CANVAS_ITEM_Z_MAX
	set_anchors_preset(PRESET_FULL_RECT)
	modulate.a = 0.0
	for i in SETTLE_FRAMES:
		await get_tree().process_frame
	if not _locate():
		queue_free()
		return
	var end_size := END_SIZE * EditorInterface.get_editor_scale()
	_logo = _mipmapped(Icons.render_logo(end_size * START_SCALE))
	if _logo == null:
		queue_free()
		return
	var tween := create_tween()
	tween.tween_method(_set_logo_size, end_size * START_SCALE, end_size, FADE_IN_TIME) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	# Nearly opaque early on the way in, and until late on the way out.
	tween.parallel().tween_property(self, "modulate:a", 1.0, FADE_IN_TIME) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_interval(HOLD_TIME)
	tween.tween_method(_set_logo_size, end_size, end_size * FADE_OUT_SCALE, FADE_OUT_TIME) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tween.parallel().tween_property(self, "modulate:a", 0.0, FADE_OUT_TIME) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tween.tween_callback(queue_free)


func _draw() -> void:
	if _logo:
		var size := Vector2(_logo_size, _logo_size * _logo.get_height() / _logo.get_width())
		draw_texture_rect(_logo, Rect2(_target - size / 2, size), false)


func _set_logo_size(value: float) -> void:
	_logo_size = value
	queue_redraw()


## Sets [member _target] to the selected file's label, in this window's
## coordinates. False when the file isn't visibly selected.
func _locate() -> bool:
	if not is_instance_valid(_dock) or not _dock.is_visible_in_tree():
		return false
	var label := Rect2()
	var widget: Control
	for list: ItemList in _dock.find_children("*", "ItemList", true, false):
		if list.is_visible_in_tree():
			label = _list_label(list)
			if label.has_area():
				widget = list
				break
	if widget == null:
		for tree: Tree in _dock.find_children("*", "Tree", true, false):
			if tree.is_visible_in_tree():
				label = _tree_label(tree)
				if label.has_area():
					widget = tree
					break
	if widget == null or widget.get_window() != get_window():
		return false
	var rect := widget.get_global_transform() * label
	# Skip a file scrolled out of view.
	if not widget.get_global_rect().has_point(rect.get_center()):
		return false
	_target = rect.get_center() - get_global_position()
	return true


func _list_label(list: ItemList) -> Rect2:
	for idx in list.get_selected_items():
		if str(list.get_item_metadata(idx)) != _path:
			continue
		var rect := list.get_item_rect(idx)
		rect.position.y -= list.get_v_scroll_bar().value
		if list.icon_mode == ItemList.ICON_MODE_TOP:
			return rect # Thumbnail grid: the item is compact already.
		var icon_width := list.fixed_icon_size.x * list.icon_scale
		var text_x := icon_width + list.get_theme_constant("h_separation")
		return _text_rect(list, rect, text_x, list.get_item_text(idx))
	return Rect2()


func _tree_label(tree: Tree) -> Rect2:
	var item := tree.get_selected()
	if item == null or str(item.get_metadata(0)) != _path:
		return Rect2()
	var depth := 0
	var parent := item.get_parent()
	while parent and parent != tree.get_root():
		depth += 1
		parent = parent.get_parent()
	var icon_width := 0.0
	if item.get_icon(0):
		icon_width = item.get_icon(0).get_width()
		if item.get_icon_max_width(0) > 0:
			icon_width = min(icon_width, item.get_icon_max_width(0))
	# Estimate where Tree draws the text: indentation, folding arrow, icon.
	var text_x := tree.get_theme_constant("item_margin") * (depth + 1) \
		+ icon_width + tree.get_theme_constant("h_separation")
	return _text_rect(tree, tree.get_item_area_rect(item, 0), text_x, item.get_text(0))


## The part of the row [param rect] holding [param text] that starts at
## [param text_x], clamped to the row.
func _text_rect(widget: Control, rect: Rect2, text_x: float, text: String) -> Rect2:
	var font := widget.get_theme_font("font")
	var text_width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1,
		widget.get_theme_font_size("font_size")).x if font else 0.0
	var from: float = min(rect.position.x + text_x, rect.end.x)
	var to: float = min(from + text_width, rect.end.x)
	return Rect2(from, rect.position.y, max(to - from, 1.0), rect.size.y)


## Mipmaps keep the shrinking logo smooth.
static func _mipmapped(texture: Texture2D) -> Texture2D:
	if texture == null:
		return null
	var image := texture.get_image()
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)
