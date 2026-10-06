@tool
extends Button
## Account button in the gallery's search row: "Log in", or the avatar and
## plan when logged in. It opens a panel with login, profile and site links.

const Auth = preload("res://addons/blendkit/auth.gd")

const USER_ICON_PATH = "res://addons/blendkit/ui/icons/user.svg"
const PANEL_WIDTH := 280
const AVATAR_SIZE := 64

var plugin: EditorPlugin

var _content: HBoxContainer
var _icon_rect: TextureRect
var _label: Label
var _arrow: TextureRect
var _popup: PopupPanel
var _popup_box: VBoxContainer
var _avatar: Texture2D
var _avatar_path := ""
var _user_icons: Dictionary = {}


## Called by the gallery once the plugin is known.
func setup(new_plugin: EditorPlugin) -> void:
	plugin = new_plugin
	text = ""
	icon = null
	_content = HBoxContainer.new()
	_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_content.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(_content)
	_icon_rect = TextureRect.new()
	_icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.add_child(_icon_rect)
	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.add_child(_label)
	_arrow = TextureRect.new()
	_arrow.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	_arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.add_child(_arrow)

	_popup = PopupPanel.new()
	_popup_box = VBoxContainer.new()
	_popup.add_child(_popup_box)
	add_child(_popup)
	_popup.popup_hide.connect(func(): set_pressed_no_signal(false))
	toggle_mode = true
	toggled.connect(_on_toggled)
	plugin.auth.changed.connect(refresh)
	refresh()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and _content:
		refresh()


## Update the button and, when open, the panel from the login state.
func refresh() -> void:
	if _content == null:
		return
	var auth = plugin.auth
	var edscale := EditorInterface.get_editor_scale()
	var icon_size := Vector2.ONE * 16 * edscale
	_icon_rect.custom_minimum_size = icon_size
	_arrow.texture = get_theme_icon("arrow", "OptionButton")
	_label.add_theme_color_override("font_color", get_theme_color("font_color", "Button"))
	_content.add_theme_constant_override("separation", int(4 * edscale))
	_update_avatar()

	if auth.login_pending:
		_label.text = "Logging in…"
		_icon_rect.texture = get_theme_icon("Timer", "EditorIcons")
		tooltip_text = "Finish logging in in your browser."
	elif auth.is_logged_in():
		var plan: String = Auth.plan_label(auth.profile)
		_label.text = plan if plan else "Logged in"
		_icon_rect.texture = _avatar if _avatar else _user_icon()
		var who: String = Auth.display_name(auth.profile)
		tooltip_text = "Logged in to Blendkit as %s." % who if who else "Logged in to Blendkit."
	else:
		_label.text = "Log in"
		_icon_rect.texture = _user_icon()
		tooltip_text = "Not logged in. Log in to download Full Plan assets."

	var style := get_theme_stylebox("normal", "Button")
	custom_minimum_size = _content.get_combined_minimum_size() + style.get_minimum_size()
	_content.offset_left = style.get_margin(SIDE_LEFT)
	_content.offset_right = -style.get_margin(SIDE_RIGHT)
	if _popup.visible:
		_fill_popup()


func _on_toggled(pressed: bool) -> void:
	if not pressed:
		_popup.hide()
		return
	_fill_popup()
	_popup.reset_size()
	var popup_size := _popup.get_contents_minimum_size()
	# Right-aligned below the button, positioned like MenuButton does it.
	var pos := get_screen_position() + Vector2(size.x * get_global_transform_with_canvas().get_scale().x - popup_size.x, size.y * get_global_transform_with_canvas().get_scale().y)
	_popup.popup(Rect2i(Vector2i(pos), Vector2i(popup_size)))


func _fill_popup() -> void:
	for child in _popup_box.get_children():
		_popup_box.remove_child(child)
		child.queue_free()
	var auth = plugin.auth
	var edscale := EditorInterface.get_editor_scale()
	_popup_box.custom_minimum_size.x = PANEL_WIDTH * edscale
	_popup_box.add_theme_constant_override("separation", int(8 * edscale))
	var connected: bool = plugin.state == plugin.State.CONNECTED

	if auth.login_pending:
		_popup_box.add_child(_text("Finish logging in in your browser…", true))
		_popup_box.add_child(_text("Log in or sign up on the page that opened, then come back here."))
		_popup_box.add_child(_buttons([_button("Cancel", "", auth.cancel_login)]))
	elif auth.is_logged_in():
		_popup_box.add_child(_profile_header())
		var plan: String = Auth.plan_label(auth.profile)
		if plan:
			var row := HBoxContainer.new()
			var plan_text := _text("Plan: %s" % plan)
			plan_text.autowrap_mode = TextServer.AUTOWRAP_OFF
			row.add_child(plan_text)
			if plan == "Free":
				var spacer := Control.new()
				spacer.size_flags_horizontal = SIZE_EXPAND_FILL
				row.add_child(spacer)
				row.add_child(_link("See Full Plan", plugin.SERVER + "/plans/pricing", true))
			_popup_box.add_child(row)
		_popup_box.add_child(_buttons([
			_link("Profile", plugin.SERVER + "/profile"),
			_link("blendkit.com", plugin.SERVER),
		]))
		_popup_box.add_child(HSeparator.new())
		_popup_box.add_child(_buttons([_button("Log Out", "", auth.logout)]))
	else:
		_popup_box.add_child(_text("Not logged in", true))
		_popup_box.add_child(_text("Free assets download without an account. Log in to download Full Plan assets right here in Godot."))
		var login := _button("Log In", "", auth.login.bind(false))
		var signup := _button("Sign Up", "", auth.login.bind(true))
		login.disabled = not connected
		signup.disabled = not connected
		_popup_box.add_child(_buttons([login, signup]))
		if not connected:
			_popup_box.add_child(_note("Logging in needs the Blendkit Client. Turn it on next to this button."))
		_popup_box.add_child(HSeparator.new())
		_popup_box.add_child(_buttons([_link("blendkit.com", plugin.SERVER)]))
	if auth.login_error and not auth.login_pending and not auth.is_logged_in():
		var error := _note(auth.login_error)
		error.add_theme_color_override("font_color", get_theme_color("error_color", "Editor"))
		_popup_box.add_child(error)
	_fit_popup.call_deferred()


## Wrapped labels know their height only once laid out at the panel width,
## so shrink the panel to its contents after a layout pass.
func _fit_popup() -> void:
	if not _popup.visible:
		return
	await get_tree().process_frame
	_popup.size = Vector2i(_popup.size.x, int(_popup_box.get_combined_minimum_size().y + _popup.get_theme_stylebox("panel").get_minimum_size().y))


func _profile_header() -> Control:
	var auth = plugin.auth
	var edscale := EditorInterface.get_editor_scale()
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", int(10 * edscale))
	var avatar := TextureRect.new()
	avatar.custom_minimum_size = Vector2.ONE * AVATAR_SIZE * edscale
	avatar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	avatar.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	avatar.texture = _avatar if _avatar else _user_icon(AVATAR_SIZE)
	row.add_child(avatar)
	var names := VBoxContainer.new()
	names.alignment = BoxContainer.ALIGNMENT_CENTER
	names.size_flags_horizontal = SIZE_EXPAND_FILL
	var who: String = Auth.display_name(auth.profile)
	names.add_child(_text(who if who else "Loading profile…", true))
	var email := str(auth.profile.get("email", "")) if auth.profile.get("email") else ""
	if email and email != who:
		names.add_child(_note(email))
	row.add_child(names)
	return row


func _text(value: String, bold := false) -> Label:
	var label := Label.new()
	label.text = value
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = SIZE_EXPAND_FILL
	if bold:
		label.add_theme_font_override("font", get_theme_font("bold", "EditorFonts"))
	return label


func _note(value: String) -> Label:
	var label := _text(value)
	label.add_theme_color_override("font_color", get_theme_color("font_disabled_color", "Editor"))
	return label


func _button(label: String, icon_name: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = label
	if icon_name:
		button.icon = get_theme_icon(icon_name, "EditorIcons")
	button.pressed.connect(func():
		_popup.hide()
		action.call())
	return button


func _link(label: String, url: String, flat := false) -> Button:
	var button := _button(label, "ExternalLink", func(): OS.shell_open(url))
	button.tooltip_text = url
	button.flat = flat
	return button


func _buttons(buttons: Array) -> HBoxContainer:
	var row := HBoxContainer.new()
	for button in buttons:
		button.size_flags_horizontal = SIZE_EXPAND_FILL
		row.add_child(button)
	return row


## Monochrome user icon matching the editor icons, rendered like the
## plugin's tab icon. size is in unscaled pixels.
func _user_icon(size := 16) -> Texture2D:
	var key := "%s %s %s" % [size, EditorInterface.get_editor_scale(), plugin.is_dark_icon_theme()]
	if _user_icons.has(key):
		return _user_icons[key]
	var svg := FileAccess.get_file_as_string(USER_ICON_PATH)
	if not plugin.is_dark_icon_theme():
		svg = svg.replace("#e0e0e0", "#5a5a5a")
	var image := Image.new()
	if svg.is_empty() or image.load_svg_from_string(svg, size * EditorInterface.get_editor_scale() / 16.0) != OK:
		return null
	_user_icons[key] = ImageTexture.create_from_image(image)
	return _user_icons[key]


func _update_avatar() -> void:
	var path: String = plugin.auth.avatar_path
	if path == _avatar_path:
		return
	_avatar_path = path
	_avatar = null
	if path.is_empty() or not FileAccess.file_exists(path):
		return
	var image := Image.new()
	if image.load(path) != OK:
		return
	_avatar = ImageTexture.create_from_image(circle_crop(image))


## The image cropped to a centered circle with a transparent outside.
static func circle_crop(image: Image) -> Image:
	var side := mini(image.get_width(), image.get_height())
	var result := image.get_region(Rect2i((image.get_width() - side) / 2, (image.get_height() - side) / 2, side, side))
	result.convert(Image.FORMAT_RGBA8)
	var r := side / 2.0
	for y in side:
		for x in side:
			# Antialias the edge over one pixel.
			var d := Vector2(x + 0.5 - r, y + 0.5 - r).length()
			var alpha := clampf(r - d, 0.0, 1.0)
			if alpha < 1.0:
				var c := result.get_pixel(x, y)
				c.a *= alpha
				result.set_pixel(x, y, c)
	return result
