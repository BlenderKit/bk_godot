@tool
extends Button
## Blendkit menu at the end of the gallery's search row: the logo with a
## Client status dot in its corner, then the editor's "more" dots. It opens
## the Client status and switch, settings and links.

const SettingsDialog = preload("res://addons/blendkit/ui/settings_dialog.gd")

enum Item { STATUS, ENABLE, RESTART, SETTINGS, WEBSITE, DOCS, ISSUES, VERSION }

const LOGO_SIZE := 16
const DOT_RADIUS := 3.5

var plugin: EditorPlugin

var _content: HBoxContainer
var _logo: TextureRect
var _dot: Control
var _dots: TextureRect
var _menu: PopupMenu
var _settings: AcceptDialog
var _logo_key := ""


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
	refresh()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and _content:
		refresh()


## Update the status dot, tooltip and, when open, the menu.
func refresh() -> void:
	if _content == null:
		return
	var edscale := EditorInterface.get_editor_scale()
	var logo_size := Vector2.ONE * LOGO_SIZE * edscale
	_logo.custom_minimum_size = logo_size
	var key := str(edscale)
	if key != _logo_key:
		_logo_key = key
		_logo.texture = _render_logo(LOGO_SIZE * edscale)
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
	# Right-aligned below the button like the account panel.
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


func _on_id_pressed(id: int) -> void:
	match id:
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


func _render_logo(px: float) -> Texture2D:
	var svg := FileAccess.get_file_as_string(plugin.LOGO_PATH)
	var image := Image.new()
	if svg.is_empty() or image.load_svg_from_string(svg, px / 320.0) != OK:
		return null
	return ImageTexture.create_from_image(image)
