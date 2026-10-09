@tool
extends PanelContainer
## Blendkit main-screen tab: search with filters, paged thumbnails and an
## asset details dialog with a Download button. Works like the Asset Store.
## The toggle next to the search switches to the assets downloaded to the
## project. The parts are the search (SearchView on %Body), the project
## assets (ProjectView on %ProjectBody) and the Downloads model.
##
## The plugin owns the Client connection. It calls handle_task() for search,
## thumbnail and download tasks from its /godot/report poll,
## drop_vanished_downloads() after each report, and on_connection_changed() /
## on_categories_changed() on updates.

const GalleryApi = preload("res://addons/blendkit/ui/gallery/gallery_api.gd")
const GalleryItemScript = preload("res://addons/blendkit/ui/gallery/gallery_item.gd")
const ClientTasks = preload("res://addons/blendkit/ui/gallery/client_tasks.gd")
const Downloads = preload("res://addons/blendkit/ui/gallery/downloads.gd")
const SearchView = preload("res://addons/blendkit/ui/gallery/search_view.gd")
const ProjectView = preload("res://addons/blendkit/ui/gallery/project_view.gd")

const SPINNER_SIZE := 128
## Spinner turns per second.
const SPINNER_SPEED := 0.75

@onready var main: VBoxContainer = %Main
@onready var search_edit: LineEdit = %SearchEdit
@onready var menu_button: Button = %MainMenuButton
@onready var project_toggle: Button = %ProjectToggle
@onready var filter_row: HFlowContainer = %FilterRow
@onready var scroll: ScrollContainer = %Scroll
@onready var border: PanelContainer = %Border
@onready var search: SearchView = %Body
@onready var project_view: ProjectView = %ProjectBody
@onready var browse_button: Button = %BrowseButton
@onready var spinner: TextureRect = %Spinner
@onready var details = %AssetDetails

## Set by the plugin before the gallery enters the tree.
var plugin: EditorPlugin
var tasks: ClientTasks
var downloads: Downloads
## assetBaseId -> {thumbnail_type: image_path}, kept across searches.
var thumb_cache: Dictionary = {}

var _was_connected := false
var _updating_theme := false
var _busy := false
## Project mode shows the downloaded assets instead of the Blendkit search.
## Each mode keeps its own query and scroll position.
var _project_mode := false
var _other_text := ""
var _other_scroll := 0
## Whether the last edit of the search box came from the mouse, which empties
## it only through the clear button (or the context menu's Clear).
var _search_mouse_edit := false
var _download_badge: Label


func _ready() -> void:
	set_process(false)
	if plugin == null:
		return
	# Spacing follows the Asset Store (EditorAssetLibrary).
	var edscale := EditorInterface.get_editor_scale()
	main.add_theme_constant_override("separation", int(10 * edscale))
	var border_style: StyleBoxEmpty = border.get_theme_stylebox("panel").duplicate()
	border_style.content_margin_left = 15 * edscale
	border_style.content_margin_top = 15 * edscale
	border_style.content_margin_right = 35 * edscale
	border_style.content_margin_bottom = 15 * edscale
	border.add_theme_stylebox_override("panel", border_style)
	# Unlike SCROLL_MODE_DISABLED (the Asset Store), SHOW_NEVER keeps the
	# results from setting the tab's minimum width, so it narrows like the
	# toolbars and the grid columns follow.
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	if "scroll_hint_mode" in scroll: # Godot 4.6+
		scroll.set("scroll_hint_mode", 2) # SCROLL_HINT_MODE_TOP_AND_LEFT
	spinner.texture = plugin.render_logo(SPINNER_SIZE * edscale)
	spinner.custom_minimum_size = Vector2.ONE * SPINNER_SIZE * edscale
	spinner.resized.connect(func(): spinner.pivot_offset = spinner.size / 2)

	tasks = ClientTasks.new()
	tasks.started.connect(plugin.update_poll_rate)
	tasks.unclaimed.connect(_on_unclaimed_task)
	downloads = Downloads.new(self, plugin, tasks)
	downloads.download_changed.connect(_on_download_changed)
	search.setup(self)
	project_view.setup(self)

	search_edit.text_changed.connect(_on_search_text_changed)
	search_edit.text_submitted.connect(_on_search_text_submitted)
	search_edit.gui_input.connect(_on_search_gui_input)
	menu_button.setup(plugin)
	plugin.auth.changed.connect(func():
		if details.visible:
			details.refresh_download())
	project_toggle.toggled.connect(_on_project_toggled)
	browse_button.pressed.connect(func(): project_toggle.button_pressed = false)
	_download_badge = Label.new()
	_download_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_download_badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_download_badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_download_badge.custom_minimum_size = Vector2.ONE * roundf(16 * edscale)
	project_toggle.add_child(_download_badge)
	_download_badge.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_download_badge.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	# Hang over the corner, clear of the icon.
	_download_badge.offset_left = 5 * edscale
	_download_badge.offset_right = 5 * edscale
	_download_badge.offset_top = -4 * edscale
	_download_badge.offset_bottom = -4 * edscale
	_update_download_badge()
	scroll.resized.connect(update_columns)

	details.gallery = self
	details.download_requested.connect(downloads.start)
	details.cancel_requested.connect(downloads.cancel)
	details.tag_selected.connect(_on_tag_selected)

	_updating_theme = true
	_update_theme()
	_updating_theme = false
	on_connection_changed()


func _process(delta: float) -> void:
	spinner.rotation = fmod(spinner.rotation + TAU * SPINNER_SPEED * delta, TAU)


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_VISIBILITY_CHANGED:
			if not plugin or not is_visible_in_tree():
				return
			# Like the Asset Store, typing goes straight to the search.
			search_edit.grab_focus()
			search.on_shown()
		NOTIFICATION_THEME_CHANGED:
			# Overriding own styles emits THEME_CHANGED again, hence the guard.
			if is_node_ready() and plugin and not _updating_theme:
				_updating_theme = true
				_update_theme()
				_updating_theme = false


func _update_theme() -> void:
	add_theme_stylebox_override("panel", get_theme_stylebox("bg", "AssetLib"))
	scroll.add_theme_stylebox_override("panel", get_theme_stylebox("panel", "Tree"))
	search_edit.right_icon = get_theme_icon("Search", "EditorIcons")
	# AssetStore is the Godot 4.7+ name of AssetLib.
	project_toggle.icon = get_theme_icon("AssetStore" if has_theme_icon("AssetStore", "EditorIcons") else "AssetLib", "EditorIcons")
	# Flat look, but the padding of a regular button like the menu button.
	project_toggle.custom_minimum_size.x = project_toggle.icon.get_width() + get_theme_stylebox("normal", "Button").get_minimum_size().x
	var edscale := EditorInterface.get_editor_scale()
	var badge_style := StyleBoxFlat.new()
	badge_style.bg_color = get_theme_color("accent_color", "Editor")
	badge_style.set_corner_radius_all(int(8 * edscale))
	# A ring in the background color keeps it apart from the pressed button.
	badge_style.set_border_width_all(maxi(1, int(2 * edscale)))
	badge_style.border_color = get_theme_color("base_color", "Editor")
	badge_style.content_margin_left = 3 * edscale
	badge_style.content_margin_right = 3 * edscale
	_download_badge.add_theme_stylebox_override("normal", badge_style)
	_download_badge.add_theme_color_override("font_color", get_theme_color("base_color", "Editor"))
	_download_badge.add_theme_font_override("font", get_theme_font("bold", "EditorFonts"))
	_download_badge.add_theme_font_size_override("font_size", int(10 * edscale))
	search.update_theme()


# MARK: plugin interface

func on_connection_changed() -> void:
	if not is_node_ready():
		return
	menu_button.refresh()
	var connected := is_client_connected()
	if connected == _was_connected:
		if not connected:
			search.update_connection_message()
		return
	_was_connected = connected
	if connected:
		search.on_connected()
		project_view.next_lookup()
		return
	# The Client cancels the app's tasks when it unsubscribes.
	search.on_disconnected()
	project_view.on_disconnected()
	downloads.on_disconnected()
	tasks.cancel_all()


func on_categories_changed() -> void:
	if is_node_ready():
		search.fill_categories()


func has_pending_work() -> bool:
	if tasks == null:
		return false
	return tasks.is_posting() or search.has_pending_work() or project_view.has_pending_work() \
		or downloads.has_pending_work()


func handle_task(task: Dictionary) -> void:
	match task.get("task_type"):
		"search", "asset_download":
			if not tasks.handle(task):
				_on_unclaimed_task(task)
		"thumbnail_download":
			_handle_thumbnail_task(task)


func drop_vanished_downloads(reported: Dictionary) -> void:
	if downloads:
		downloads.drop_vanished(reported)


## A task the gallery didn't start: an asset_download is Send to Godot on
## blendkit.com.
func _on_unclaimed_task(task: Dictionary) -> void:
	if task.get("task_type") == "asset_download":
		downloads.handle_web_task(task)


func is_client_connected() -> bool:
	return plugin != null and plugin.state == plugin.State.CONNECTED


# MARK: layout

## Width for the results inside the scroll border.
func content_width() -> float:
	return scroll.size.x - border.get_theme_stylebox("panel").get_minimum_size().x


func update_columns() -> void:
	var item_width := GalleryItemScript.THUMB_SIZE * EditorInterface.get_editor_scale()
	var separation := search.grid.get_theme_constant("h_separation")
	var available := content_width() - scroll.get_v_scroll_bar().size.x
	search.grid.columns = maxi(1, int((available + separation) / (item_width + separation)))
	project_view.grid.columns = search.grid.columns
	if search.has_pages():
		search.update_pages()


## New results start at the top, also when they arrive in project mode.
func reset_search_scroll() -> void:
	if _project_mode:
		_other_scroll = 0
	else:
		scroll.scroll_vertical = 0


## Dims the results with a spinning logo over them, like the Asset Store
## while it waits for a response.
func set_busy(busy: bool) -> void:
	_busy = busy
	spinner.rotation = 0
	_update_busy()


## The busy state belongs to the search, so it doesn't show in project mode.
func _update_busy() -> void:
	var busy := _busy and not _project_mode
	scroll.modulate = Color(1, 1, 1, 0.5) if busy else Color.WHITE
	spinner.visible = busy
	set_process(busy)


# MARK: search box and project toggle

## The search query, also while the box shows the project query.
func blendkit_query() -> String:
	return _other_text if _project_mode else search_edit.text


## Searching Blendkit waits for Enter, like the Blender add-on, except the
## clear button, which shows the default results right away.
func _on_search_text_changed(text: String) -> void:
	if _project_mode:
		project_view.filter()
	elif text.is_empty() and _search_mouse_edit:
		search.request_search()


## Runs before the box handles the event, so the text change that follows
## knows whether it came from the keyboard or the mouse.
func _on_search_gui_input(event: InputEvent) -> void:
	if event is InputEventKey or event is InputEventMouseButton:
		_search_mouse_edit = event is InputEventMouseButton


func _on_search_text_submitted(_text: String) -> void:
	if _project_mode:
		project_view.filter()
	else:
		search.request_search()


func _on_tag_selected(tag: String) -> void:
	details.hide()
	search_edit.text = tag
	_on_search_text_submitted(tag)


## Switches between the search and the project assets. Each keeps its query
## and scroll position, and the search isn't run again.
func _on_project_toggled(pressed: bool) -> void:
	if pressed == _project_mode:
		return
	_project_mode = pressed
	var text := search_edit.text
	var scroll_position := scroll.scroll_vertical
	search_edit.text = _other_text
	search_edit.caret_column = search_edit.text.length()
	_other_text = text
	search_edit.placeholder_text = "Search downloaded project assets" if pressed else "Search Blendkit assets (ENTER to search)"
	filter_row.visible = not pressed
	search.visible = not pressed
	project_view.visible = pressed
	_update_busy()
	if pressed:
		project_view.refresh()
	search_edit.grab_focus()
	# The scroll range follows the new content after layout.
	var restore := _other_scroll
	_other_scroll = scroll_position
	await get_tree().process_frame
	scroll.scroll_vertical = restore


# MARK: thumbnails

func _handle_thumbnail_task(task: Dictionary) -> void:
	var status: String = task.get("status", "")
	var data = task.get("data")
	if not status in ["finished", "error"] or not data is Dictionary:
		return
	var base_id := str(data.get("assetBaseId", ""))
	var type := str(data.get("thumbnail_type", ""))
	if status == "error":
		plugin.bk_log(plugin.LogLevel.DEBUG, "Thumbnail failed: %s" % task.get("message", ""))
		search.on_thumbnail(base_id, type, "")
		return
	var path := str(data.get("image_path", ""))
	if not thumb_cache.has(base_id):
		thumb_cache[base_id] = {}
	thumb_cache[base_id][type] = path
	search.on_thumbnail(base_id, type, path)
	if type == "small":
		project_view.add_thumbnail(base_id, path)
	if details.visible and str(details.asset.get("assetBaseId", "")) == base_id:
		details.on_thumbnail(type, GalleryApi.load_texture(path))


# MARK: details and downloads

func open_details(asset: Dictionary) -> void:
	details.show_asset(asset, thumb_cache.get(str(asset.get("assetBaseId", "")), {}))


func get_download(base_id: String) -> Dictionary:
	return downloads.get_download(base_id)


func is_downloaded(asset: Dictionary) -> bool:
	var dir := GalleryApi.asset_download_dir(plugin.absolute_download_path, asset)
	return DirAccess.dir_exists_absolute(dir) and not DirAccess.get_files_at(dir).is_empty()


## Show the download state in the details when open, and in the badge.
func _on_download_changed(id: String) -> void:
	if details.visible and str(details.asset.get("assetBaseId", "")) == id:
		details.refresh_download()
	_update_download_badge()


func _update_download_badge() -> void:
	var count := downloads.active_count()
	_download_badge.text = str(count)
	_download_badge.visible = count > 0
	project_toggle.tooltip_text = "Show assets downloaded to this project"
	if count > 0:
		project_toggle.tooltip_text += "\n%d %s in progress" % [count, "download" if count == 1 else "downloads"]
