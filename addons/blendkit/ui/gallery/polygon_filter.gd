@tool
extends Button
## The gallery's Polygons filter: a dropdown showing the range, like Any or
## 10 - 10k. It opens a range slider over polygon count stops, with Min and
## Max boxes below for exact counts and Any to clear the range.

signal range_changed
## The popup closed, with any typed counts applied.
signal closed

const GalleryApi = preload("res://addons/blendkit/ui/gallery/gallery_api.gd")

const POPUP_WIDTH := 340

var min_faces := 0
var max_faces := GalleryApi.NO_LIMIT

var _popup: PopupPanel
var _slider: RangeSlider
var _min_edit: LineEdit
var _max_edit: LineEdit
var _any_button: Button


## Called by the search view with the saved range.
func setup(new_min: int, new_max: int) -> void:
	var edscale := EditorInterface.get_editor_scale()
	theme_type_variation = "OptionButton"
	alignment = HORIZONTAL_ALIGNMENT_LEFT
	icon_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	toggle_mode = true
	tooltip_text = "Polygon count of the assets."
	icon = get_theme_icon("GuiOptionArrow", "EditorIcons")

	_popup = PopupPanel.new()
	add_child(_popup)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", int(8 * edscale))
	_popup.add_child(box)
	_slider = RangeSlider.new()
	_slider.custom_minimum_size.x = POPUP_WIDTH * edscale
	_slider.moved.connect(func(low: int, high: int):
		_set_range(GalleryApi.POLYGON_STOPS[low], GalleryApi.POLYGON_STOPS[high]))
	box.add_child(_slider)
	var edits := HBoxContainer.new()
	box.add_child(edits)
	_min_edit = _count_edit(edits, "Min", "0")
	_max_edit = _count_edit(edits, "Max", "∞")
	edits.add_child(VSeparator.new())
	_any_button = Button.new()
	_any_button.text = "Any"
	_any_button.tooltip_text = "Any polygon count."
	_any_button.pressed.connect(func(): _set_range(0, GalleryApi.NO_LIMIT))
	edits.add_child(_any_button)

	_popup.popup_hide.connect(func():
		_apply_edits()
		set_pressed_no_signal(false)
		closed.emit())
	toggled.connect(_on_toggled)
	min_faces = new_min
	max_faces = new_max
	_show_range()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and _popup:
		icon = get_theme_icon("GuiOptionArrow", "EditorIcons")


func _count_edit(parent: HBoxContainer, label_text: String, placeholder: String) -> LineEdit:
	var label := Label.new()
	label.text = label_text
	parent.add_child(label)
	var edit := LineEdit.new()
	edit.placeholder_text = placeholder
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.tooltip_text = "An exact polygon count like 2500, 2.5k or 2M."
	edit.text_submitted.connect(func(_text): _apply_edits())
	edit.focus_exited.connect(_apply_edits)
	parent.add_child(edit)
	return edit


func _on_toggled(pressed: bool) -> void:
	if not pressed:
		_popup.hide()
		return
	_popup.reset_size()
	var canvas_scale := get_global_transform_with_canvas().get_scale()
	# Below the button like OptionButton, kept within the editor window.
	var pos := get_screen_position() + Vector2(0, size.y * canvas_scale.y)
	var window := get_window()
	pos.x = maxf(window.position.x, minf(pos.x, window.position.x + window.size.x - _popup.size.x))
	_popup.popup(Rect2i(Vector2i(pos), _popup.size))


## Applies the typed counts; empty is no limit, anything else unreadable
## shows the current range again.
func _apply_edits() -> void:
	var new_min := 0 if _min_edit.text.strip_edges().is_empty() else GalleryApi.parse_count(_min_edit.text)
	var new_max := GalleryApi.NO_LIMIT if _max_edit.text.strip_edges().is_empty() else GalleryApi.parse_count(_max_edit.text)
	if new_min < 0 or (new_max < 0 and not _max_edit.text.strip_edges().is_empty()):
		_show_range()
		return
	if new_max != GalleryApi.NO_LIMIT and new_min > new_max:
		var swap := new_min
		new_min = new_max
		new_max = swap
	_set_range(new_min, new_max)


func _set_range(new_min: int, new_max: int) -> void:
	var changed := new_min != min_faces or new_max != max_faces
	min_faces = new_min
	max_faces = new_max
	_show_range()
	if changed:
		range_changed.emit()


func _show_range() -> void:
	text = GalleryApi.polygon_label(min_faces, max_faces)
	_slider.set_positions(GalleryApi.polygon_position(min_faces), GalleryApi.polygon_position(max_faces))
	_min_edit.text = "" if min_faces <= 0 else GalleryApi.short_count(min_faces)
	_max_edit.text = "" if max_faces == GalleryApi.NO_LIMIT else GalleryApi.short_count(max_faces)
	_any_button.disabled = min_faces <= 0 and max_faces == GalleryApi.NO_LIMIT


## Two grabbers over the evenly spaced POLYGON_STOPS, labeled below.
## Dragging snaps to the stops; typed counts sit between them.
class RangeSlider extends Control:
	## The grabbers were dragged to these POLYGON_STOPS indices.
	signal moved(low: int, high: int)

	var low := 0.0
	var high := float(GalleryApi.POLYGON_STOPS.size() - 1)
	## The grabber dragged or under the mouse: 0 low, 1 high, -1 none.
	var _dragging := -1
	var _hovered := -1

	func _init() -> void:
		mouse_exited.connect(func():
			_hovered = -1
			queue_redraw())

	func set_positions(new_low: float, new_high: float) -> void:
		low = new_low
		high = new_high
		queue_redraw()

	func _get_minimum_size() -> Vector2:
		var grabber := get_theme_icon("grabber", "HSlider")
		var font := get_theme_font("font", "Label")
		var gap := 4 * EditorInterface.get_editor_scale()
		return Vector2(0, grabber.get_height() + gap + font.get_height(get_theme_font_size("font_size", "Label")))

	## Half of the widest stop label or grabber, so both fit at the ends.
	func _margin() -> float:
		var font := get_theme_font("font", "Label")
		var font_size := get_theme_font_size("font_size", "Label")
		var widest: float = get_theme_icon("grabber", "HSlider").get_width()
		for stop in GalleryApi.POLYGON_STOPS:
			widest = maxf(widest, font.get_string_size(GalleryApi.short_count(stop), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x)
		return ceilf(widest / 2)

	func _x(position: float) -> float:
		var margin := _margin()
		return margin + (size.x - 2 * margin) * position / (GalleryApi.POLYGON_STOPS.size() - 1)

	func _stop_at(x: float) -> int:
		var margin := _margin()
		var last := GalleryApi.POLYGON_STOPS.size() - 1
		return clampi(roundi((x - margin) / (size.x - 2 * margin) * last), 0, last)

	func _grabber_at(x: float) -> int:
		if is_equal_approx(low, high):
			# On top of each other, like an exact count: left of them moves
			# the low one.
			return 0 if x < _x(low) else 1
		return 0 if absf(x - _x(low)) < absf(x - _x(high)) else 1

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_dragging = _grabber_at(event.position.x)
				_drag_to(event.position.x)
			else:
				_dragging = -1
				queue_redraw()
			accept_event()
		elif event is InputEventMouseMotion:
			# Released outside the popup, the release doesn't reach the slider.
			if _dragging >= 0 and not event.button_mask & MOUSE_BUTTON_MASK_LEFT:
				_dragging = -1
				queue_redraw()
			if _dragging >= 0:
				_drag_to(event.position.x)
			else:
				var hovered := _grabber_at(event.position.x)
				if hovered != _hovered:
					_hovered = hovered
					queue_redraw()

	## The grabbers stay at least a stop apart.
	func _drag_to(x: float) -> void:
		var stop := _stop_at(x)
		var last := GalleryApi.POLYGON_STOPS.size() - 1
		var new_low := roundi(low)
		var new_high := roundi(high)
		if _dragging == 0:
			new_low = mini(stop, last - 1)
			new_high = maxi(new_high, new_low + 1)
		else:
			new_high = maxi(stop, 1)
			new_low = mini(new_low, new_high - 1)
		if new_low != low or new_high != high:
			set_positions(new_low, new_high)
			moved.emit(new_low, new_high)

	func _draw() -> void:
		var grabber := get_theme_icon("grabber", "HSlider")
		var highlight := get_theme_icon("grabber_highlight", "HSlider")
		var track := get_theme_stylebox("slider", "HSlider")
		var area := get_theme_stylebox("grabber_area", "HSlider")
		var font := get_theme_font("font", "Label")
		var font_size := get_theme_font_size("font_size", "Label")
		var font_color := get_theme_color("font_color", "Label")
		var dim_color := Color(font_color, font_color.a * 0.5)
		var center_y := grabber.get_height() / 2.0
		var track_height := track.get_minimum_size().y
		var start := _x(0)
		var end := _x(GalleryApi.POLYGON_STOPS.size() - 1)
		draw_style_box(track, Rect2(start, center_y - track_height / 2, end - start, track_height))
		draw_style_box(area, Rect2(_x(low), center_y - track_height / 2, _x(high) - _x(low), track_height))
		var label_y := grabber.get_height() + 4 * EditorInterface.get_editor_scale() + font.get_ascent(font_size)
		for i in GalleryApi.POLYGON_STOPS.size():
			var label := GalleryApi.short_count(GalleryApi.POLYGON_STOPS[i])
			var width := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
			var color := font_color if i >= low - 0.001 and i <= high + 0.001 else dim_color
			draw_string(font, Vector2(roundf(_x(i) - width / 2), label_y), label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)
		for i in 2:
			var texture := highlight if i == _dragging or (_dragging < 0 and i == _hovered) else grabber
			var x := _x(low if i == 0 else high)
			draw_texture(texture, Vector2(roundf(x - texture.get_width() / 2.0), roundf(center_y - texture.get_height() / 2.0)))
