@tool
extends Button
## Blendkit menu at the end of the gallery's search row: the logo with a
## Client status dot in its corner, then the editor's "more" dots. It opens
## the Client status and switch, the account and plan, settings and links.

const Auth = preload("res://addons/blendkit/auth.gd")
const GalleryApi = preload("res://addons/blendkit/ui/gallery/gallery_api.gd")
const SettingsDialog = preload("res://addons/blendkit/ui/settings_dialog.gd")

enum Item {
	PROFILE, EMAIL, PLAN, LOGIN, SIGNUP, LOGOUT, LOGIN_STATUS, CANCEL_LOGIN, LOGIN_ERROR,
	STATUS, ENABLE, RESTART, SETTINGS, WEBSITE, DOCS, ISSUES, VERSION,
}

const USER_ICON_PATH = "res://addons/blendkit/ui/icons/user.svg"
const LOGO_SIZE := 16
const DOT_RADIUS := 3.5
const AVATAR_SIZE := 24

var plugin: EditorPlugin

var _content: HBoxContainer
var _logo: TextureRect
var _dot: Control
var _dots: TextureRect
var _menu: PopupMenu
var _settings: AcceptDialog
var _logo_key := ""
var _avatar: Texture2D
var _avatar_key := ""
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
	_logo = TextureRect.new()
	_logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Containers floor shrink-centered positions, so icons land on whole
	# pixels and draw crisp.
	_logo.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_content.add_child(_logo)
	_dot = Control.new()
	_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dot.draw.connect(_draw_dot)
	_logo.add_child(_dot)
	_dots = TextureRect.new()
	_dots.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	_dots.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dots.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_content.add_child(_dots)

	_menu = PopupMenu.new()
	add_child(_menu)
	_menu.id_pressed.connect(_on_id_pressed)
	_menu.popup_hide.connect(func(): set_pressed_no_signal(false))
	_settings = SettingsDialog.new()
	add_child(_settings)
	_settings.setup(plugin)
	toggle_mode = true
	toggled.connect(_on_toggled)
	plugin.auth.changed.connect(refresh)
	refresh()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and _content:
		refresh()


## Update the status dot, tooltip and, when open, the menu, e.g. after the
## Client or the login changed.
func refresh() -> void:
	if _content == null:
		return
	var edscale := EditorInterface.get_editor_scale()
	var logo_size := Vector2.ONE * LOGO_SIZE * edscale
	_logo.custom_minimum_size = logo_size
	var key := str(edscale)
	if key != _logo_key:
		_logo_key = key
		_logo.texture = plugin.render_logo(LOGO_SIZE * edscale)
	# Bottom right corner of the logo, half outside like a badge.
	var dot_size := Vector2.ONE * (DOT_RADIUS + 1.5) * 2 * edscale
	_dot.position = logo_size - dot_size * 0.6
	_dot.size = dot_size
	_dot.queue_redraw()
	_dots.texture = get_theme_icon("GuiTabMenuHl", "EditorIcons")
	_content.add_theme_constant_override("separation", int(4 * edscale))
	# Only the logo dims, the dot stays readable.
	_logo.self_modulate.a = 0.5 if plugin.state == plugin.State.DISABLED else 1.0
	tooltip_text = "Blendkit menu\nClient: %s" % plugin.status_text()

	var style := get_theme_stylebox("normal", "Button")
	custom_minimum_size = _content.get_combined_minimum_size() + style.get_minimum_size()
	# As tall as a text button, like the Asset Store's search row buttons.
	var font := get_theme_font("font", "Button")
	var font_height := font.get_height(get_theme_font_size("font_size", "Button"))
	custom_minimum_size.y = maxf(custom_minimum_size.y, font_height + style.get_minimum_size().y)
	_content.offset_left = style.get_margin(SIDE_LEFT)
	_content.offset_right = -style.get_margin(SIDE_RIGHT)
	if _menu.visible:
		_fill_menu()


func status_color() -> Color:
	if plugin.state == plugin.State.CONNECTED and plugin.failed_requests == 0:
		return get_theme_color("success_color", "Editor")
	if plugin.state == plugin.State.FAILED:
		return get_theme_color("error_color", "Editor")
	if plugin.state == plugin.State.DISABLED:
		return get_theme_color("font_disabled_color", "Editor")
	# Looking for, starting or reconnecting to the Client
	return get_theme_color("warning_color", "Editor")


func _draw_dot() -> void:
	var edscale := EditorInterface.get_editor_scale()
	var center := _dot.size / 2
	# A ring in the button color separates the dot from the logo.
	var ring := get_theme_color("base_color", "Editor")
	var style := get_theme_stylebox("normal", "Button")
	if style is StyleBoxFlat:
		ring = style.bg_color
	ring.a = 1.0
	_dot.draw_circle(center, (DOT_RADIUS + 1.5) * edscale, ring)
	_dot.draw_circle(center, DOT_RADIUS * edscale, status_color())


func _on_toggled(pressed: bool) -> void:
	if not pressed:
		_menu.hide()
		return
	_fill_menu()
	_menu.reset_size()
	var canvas_scale := get_global_transform_with_canvas().get_scale()
	# Right-aligned below the button, positioned like MenuButton does it.
	var pos := get_screen_position() + Vector2(size.x * canvas_scale.x - _menu.size.x, size.y * canvas_scale.y)
	_menu.popup(Rect2i(Vector2i(pos), _menu.size))


func _fill_menu() -> void:
	_menu.clear()
	_menu.add_icon_item(plugin.get_state_icon(), "Client: %s" % plugin.status_text(), Item.STATUS)
	_menu.set_item_disabled(-1, true)
	_menu.add_check_item("Enable Blendkit Client", Item.ENABLE)
	_menu.set_item_checked(-1, plugin.client_enabled)
	_menu.set_item_tooltip(-1, "The Blendkit Client searches and downloads assets and connects Send to Godot on blendkit.com.")
	if plugin.state == plugin.State.FAILED:
		_menu.add_icon_item(get_theme_icon("Reload", "EditorIcons"), "Restart Client", Item.RESTART)
	_menu.add_separator("Account")
	_fill_account()
	_menu.add_separator()
	_menu.add_icon_item(get_theme_icon("Tools", "EditorIcons"), "Settings…", Item.SETTINGS)
	_menu.add_separator()
	_menu.add_icon_item(get_theme_icon("ExternalLink", "EditorIcons"), "blendkit.com", Item.WEBSITE)
	_menu.set_item_tooltip(-1, plugin.SERVER)
	_menu.add_icon_item(get_theme_icon("Help", "EditorIcons"), "Documentation", Item.DOCS)
	_menu.set_item_tooltip(-1, plugin.DOCS_URL)
	_menu.add_icon_item(get_theme_icon("Debug", "EditorIcons"), "Report an Issue", Item.ISSUES)
	_menu.set_item_tooltip(-1, plugin.ISSUES_URL)
	_menu.add_separator()
	_menu.add_item("Blendkit v%s" % plugin.get_addon_version(), Item.VERSION)
	_menu.set_item_disabled(-1, true)


## Who is logged in and the plan on top, then logging in or out.
func _fill_account() -> void:
	var auth = plugin.auth
	var logged_in: bool = auth.is_logged_in()
	if logged_in:
		_update_avatar()
		var who: String = Auth.display_name(auth.profile)
		_menu.add_icon_item(_avatar if _avatar else _user_icon(AVATAR_SIZE), who if who else "Loading profile…", Item.PROFILE)
		_menu.set_item_icon_max_width(-1, int(AVATAR_SIZE * EditorInterface.get_editor_scale()))
		_menu.set_item_tooltip(-1, "Open your profile on blendkit.com.")
		var email := str(auth.profile.get("email", "")) if auth.profile.get("email") else ""
		if email and email != who:
			_menu.add_item(email, Item.EMAIL)
			_menu.set_item_disabled(-1, true)
	else:
		_menu.add_icon_item(_user_icon(), "Not logged in", Item.PROFILE)
		_menu.set_item_disabled(-1, true)

	# Without an account, only free assets download, as with the Free plan.
	var plan: String = Auth.plan_label(auth.profile) if logged_in else "Free"
	if plan.is_empty():
		_menu.add_icon_item(get_theme_icon("Favorites", "EditorIcons"), "Plan: …", Item.PLAN)
		_menu.set_item_disabled(-1, true)
	else:
		_menu.add_icon_item(get_theme_icon("Favorites", "EditorIcons"), "Plan: %s" % plan, Item.PLAN)
		if logged_in:
			_menu.set_item_tooltip(-1, plugin.SERVER + "/plans/pricing")
		else:
			_menu.set_item_tooltip(-1, "Free assets download without an account. Log in to download Full Plan assets.\n" + plugin.SERVER + "/plans/pricing")

	if auth.login_pending:
		var status := "Starting Blendkit Client…" if auth.is_waiting_for_client() else "Finish logging in in your browser…"
		_menu.add_icon_item(get_theme_icon("Timer", "EditorIcons"), status, Item.LOGIN_STATUS)
		_menu.set_item_disabled(-1, true)
		_menu.add_icon_item(get_theme_icon("Close", "EditorIcons"), "Cancel Login", Item.CANCEL_LOGIN)
	elif logged_in:
		_menu.add_item("Log Out", Item.LOGOUT)
	else:
		var tooltip := "" if plugin.client_enabled else "\nThis turns on the Blendkit Client, which logging in needs."
		_menu.add_item("Log In…", Item.LOGIN)
		_menu.set_item_tooltip(-1, "Log in to Blendkit in your browser." + tooltip)
		_menu.add_item("Sign Up…", Item.SIGNUP)
		_menu.set_item_tooltip(-1, "Create a Blendkit account in your browser." + tooltip)
		if auth.login_error:
			_menu.add_icon_item(get_theme_icon("StatusError", "EditorIcons"), auth.login_error, Item.LOGIN_ERROR)
			_menu.set_item_disabled(-1, true)


func _on_id_pressed(id: int) -> void:
	match id:
		Item.PROFILE:
			OS.shell_open(plugin.SERVER + "/profile")
		Item.PLAN:
			OS.shell_open(plugin.SERVER + "/plans/pricing")
		Item.LOGIN:
			plugin.auth.login(false)
		Item.SIGNUP:
			plugin.auth.login(true)
		Item.LOGOUT:
			plugin.auth.logout()
		Item.CANCEL_LOGIN:
			plugin.auth.cancel_login()
		Item.ENABLE:
			plugin.set_client_enabled(not plugin.client_enabled)
		Item.RESTART:
			plugin.restart_client()
		Item.SETTINGS:
			_settings.popup_centered()
		Item.WEBSITE:
			OS.shell_open(plugin.SERVER)
		Item.DOCS:
			OS.shell_open(plugin.DOCS_URL)
		Item.ISSUES:
			OS.shell_open(plugin.ISSUES_URL)


## Monochrome user icon matching the editor icons, rendered like the
## plugin's tab icon. size is in unscaled pixels.
func _user_icon(size := 16) -> Texture2D:
	var key := "%s %s %s" % [size, EditorInterface.get_editor_scale(), plugin.is_dark_icon_theme()]
	if not _user_icons.has(key):
		_user_icons[key] = plugin.render_svg(USER_ICON_PATH, size * EditorInterface.get_editor_scale() / 16.0, true)
	return _user_icons[key]


## The avatar as a round icon at its menu size.
func _update_avatar() -> void:
	var px := int(AVATAR_SIZE * EditorInterface.get_editor_scale())
	var path: String = plugin.auth.avatar_path
	var key := "%s %s" % [path, px]
	if key == _avatar_key:
		return
	_avatar_key = key
	_avatar = null
	var image := GalleryApi.load_image(path)
	if not image:
		return
	image = circle_crop(image, px)
	_avatar = ImageTexture.create_from_image(image)


## The image cropped to a centered circle with a transparent outside,
## scaled to [param px] first when given, so fewer pixels are masked.
static func circle_crop(image: Image, px: int = 0) -> Image:
	var side := mini(image.get_width(), image.get_height())
	var result := image.get_region(Rect2i((image.get_width() - side) / 2, (image.get_height() - side) / 2, side, side))
	if px > 0:
		result.resize(px, px, Image.INTERPOLATE_LANCZOS)
		side = px
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
