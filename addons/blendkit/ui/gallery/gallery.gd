@tool
extends PanelContainer
## Blendkit main-screen tab: search with filters, paged thumbnails and an
## asset details dialog with a Download button. Works like the Asset Store.
## The toggle next to the search switches to the assets downloaded to the
## project, see ProjectAssets.
##
## The plugin owns the Client connection. It calls handle_task() for search,
## thumbnail and download tasks from its /godot/report poll,
## drop_vanished_downloads() after each report, and on_connection_changed() /
## on_categories_changed() on updates.

const GalleryApi = preload("res://addons/blendkit/ui/gallery/gallery_api.gd")
const GalleryItemScript = preload("res://addons/blendkit/ui/gallery/gallery_item.gd")
const ProjectAssets = preload("res://addons/blendkit/ui/gallery/project_assets.gd")
const gallery_item_scene = preload("res://addons/blendkit/ui/gallery/gallery_item.tscn")

const PAGE_SIZE := 30
## How long to keep polling fast for thumbnails after results arrive.
const THUMBS_WAIT_MS := 20000
const ACTIVE_DOWNLOAD := ["posting", "created", "progress"]
const SPINNER_SIZE := 128
## Spinner turns per second.
const SPINNER_SPEED := 0.75
## How long before a Send to Godot task first shows its asset folder may have
## changed, and how long after to keep looking for it, in seconds.
const WEB_FOLDER_SLACK := 5
const WEB_FOLDER_SEARCH := 30
const WEB_DOWNLOAD_NAME := "Send to Godot"
## Short Model Format labels for the filter row.
const FORMAT_LABELS := {"blend": "Blender (.blend)", "gltf_godot": "glTF (.glb)"}

@onready var main: VBoxContainer = %Main
@onready var search_edit: LineEdit = %SearchEdit
@onready var menu_button: Button = %MainMenuButton
@onready var project_toggle: Button = %ProjectToggle
@onready var sort_option: OptionButton = %SortOption
@onready var type_option: OptionButton = %TypeOption
@onready var category_option: OptionButton = %CategoryOption
@onready var filter_row: HFlowContainer = %FilterRow
@onready var free_check: CheckBox = %FreeCheck
@onready var format_option: OptionButton = %FormatOption
@onready var scroll: ScrollContainer = %Scroll
@onready var border: PanelContainer = %Border
@onready var body: VBoxContainer = %Body
@onready var message_box: VBoxContainer = %MessageBox
@onready var message_label: Label = %MessageLabel
@onready var message_button: Button = %MessageButton
@onready var top_pages: HBoxContainer = %TopPages
@onready var grid: GridContainer = %Grid
@onready var bottom_pages: HBoxContainer = %BottomPages
@onready var spinner: TextureRect = %Spinner
@onready var project_body: VBoxContainer = %ProjectBody
@onready var project_message: Label = %ProjectMessage
@onready var project_grid: GridContainer = %ProjectGrid
@onready var browse_button: Button = %BrowseButton
@onready var categories_timer: Timer = %CategoriesTimer
@onready var details = %AssetDetails

## Set by the plugin before the gallery enters the tree.
var plugin: EditorPlugin

var page := 1
var count := 0
var results: Array = []
## assetBaseId -> {thumbnail_type: image_path}, kept across searches.
var thumb_cache: Dictionary = {}
## assetBaseId -> GalleryItem on the current page.
var items: Dictionary = {}
## assetBaseId -> {task_id, status, progress, message, file_type, file_path}
var downloads: Dictionary = {}
## Send to Godot downloads from blendkit.com, task_id -> {task_id, status,
## progress, message, since, folder, id, asset_type}. Their tasks don't say
## which asset they download, so the staging folder is guessed, see
## ProjectAssets.recent_download_folder().
var web_downloads: Dictionary = {}

var _search_started := false
var _pending_search := false
var _searching := false
var _search_seq := 0
var _search_task_id := ""
var _search_url := ""
var _search_text := ""
var _search_error := ""
## Finished tasks that arrived before the POST that started them returned.
var _early_search_tasks: Dictionary = {}
var _early_download_tasks: Dictionary = {}
var _download_posts := 0
var _thumbs_missing := 0
var _thumbs_deadline := 0
var _was_connected := false
var _fetching_categories := false
var _message_action := Callable()
var _updating_theme := false
var _page_count := 0
var _busy := false

## Project mode shows the downloaded assets instead of the Blendkit search.
## Each mode keeps its own query and scroll position.
var _project_mode := false
var _other_text := ""
var _other_scroll := 0
## Whether the last edit of the search box came from the mouse, which empties
## it only through the clear button (or the context menu's Clear).
var _search_mouse_edit := false
var project: ProjectAssets
## Scanned asset folders with their tiles, see ProjectAssets.scan().
var _project_entries: Array = []
var _project_signature := ""
## assetBaseId or task_id -> project tile of a download in progress.
var _project_download_items: Dictionary = {}
var _download_badge: Label
## Whether leftover staging folders were cleared since connecting.
var _staging_cleared := false
## Asset id -> asset type of unknown folders to look up on Blendkit.
var _lookup_queue: Dictionary = {}
var _lookup_id := ""
var _lookup_type := ""
var _lookup_task_id := ""
var _lookup_posting := false
var _early_lookup_tasks: Dictionary = {}
## Asset ids not found on Blendkit; not looked up again this session.
var _lookup_failed: Dictionary = {}


func _ready() -> void:
	set_process(false)
	if plugin == null:
		return
	# Spacing follows the Asset Store (EditorAssetLibrary).
	var edscale := EditorInterface.get_editor_scale()
	main.add_theme_constant_override("separation", int(10 * edscale))
	body.add_theme_constant_override("separation", int(20 * edscale))
	project_body.add_theme_constant_override("separation", int(20 * edscale))
	# Filters share one line when they fit and wrap otherwise.
	filter_row.add_theme_constant_override("h_separation", int(12 * edscale))
	filter_row.add_theme_constant_override("v_separation", int(6 * edscale))
	category_option.custom_minimum_size.x = 140 * edscale
	grid.add_theme_constant_override("h_separation", int(10 * edscale))
	grid.add_theme_constant_override("v_separation", int(10 * edscale))
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
	spinner.texture = _render_logo(SPINNER_SIZE * edscale)
	spinner.custom_minimum_size = Vector2.ONE * SPINNER_SIZE * edscale
	spinner.resized.connect(func(): spinner.pivot_offset = spinner.size / 2)

	for sort in GalleryApi.SORTS:
		sort_option.add_item(sort[1])
	for asset_type in GalleryApi.ASSET_TYPES:
		type_option.add_item(GalleryApi.ASSET_TYPE_LABELS[asset_type])
	for format in plugin.MODEL_FORMATS:
		format_option.add_item(FORMAT_LABELS.get(format[0], format[1]))
	sort_option.select(maxi(0, GalleryApi.SORTS.map(func(s): return s[0]).find(_get_meta("gallery_sort", "relevance"))))
	type_option.select(maxi(0, GalleryApi.ASSET_TYPES.find(_get_meta("gallery_type", "model"))))
	free_check.button_pressed = _get_meta("gallery_free", false)
	_on_model_format_changed()
	_update_type_filters()
	_fill_categories()

	search_edit.text_changed.connect(_on_search_text_changed)
	search_edit.text_submitted.connect(_on_search_text_submitted)
	search_edit.gui_input.connect(_on_search_gui_input)
	sort_option.item_selected.connect(_on_sort_selected)
	type_option.item_selected.connect(_on_type_selected)
	category_option.item_selected.connect(func(_i): request_search())
	free_check.toggled.connect(_on_filter_toggled.bind("gallery_free"))
	format_option.item_selected.connect(func(i): plugin.set_model_format(plugin.MODEL_FORMATS[i][0]))
	plugin.model_format_changed.connect(_on_model_format_changed)
	menu_button.setup(plugin)
	plugin.auth.account_changed.connect(_on_account_changed)
	plugin.auth.changed.connect(func():
		if details.visible:
			details.refresh_download())
	message_button.pressed.connect(_on_message_button_pressed)
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
	project = ProjectAssets.new()
	EditorInterface.get_resource_filesystem().filesystem_changed.connect(_on_project_files_changed)
	categories_timer.timeout.connect(_fetch_categories)
	scroll.resized.connect(_update_columns)

	details.gallery = self
	details.download_requested.connect(_on_download_requested)
	details.cancel_requested.connect(_on_cancel_requested)
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
			# The first search runs when the tab is first shown.
			if not _search_started:
				_search_started = true
				request_search()
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


# MARK: plugin interface

func on_connection_changed() -> void:
	if not is_node_ready():
		return
	menu_button.refresh()
	var connected := _is_connected()
	if connected == _was_connected:
		if not connected and _pending_search:
			_show_connection_message()
		return
	_was_connected = connected
	if connected:
		if plugin.categories.is_empty():
			# categories_update comes once per subscription; fetch it if missed
			categories_timer.start()
		if _pending_search:
			_run_search()
		_next_lookup()
		return

	# The Client cancels the app's tasks when it unsubscribes.
	categories_timer.stop()
	if _searching:
		_searching = false
		_search_seq += 1
		_pending_search = true
		_set_busy(false)
		_clear_results()
	_search_url = ""
	_search_task_id = ""
	if not _lookup_id.is_empty():
		_lookup_queue[_lookup_id] = _lookup_type
	_lookup_id = ""
	_lookup_task_id = ""
	for base_id in downloads:
		var dl: Dictionary = downloads[base_id]
		if dl.status in ACTIVE_DOWNLOAD:
			dl.status = "error"
			dl.message = "Blendkit Client disconnected"
			_refresh_download(base_id)
	for task_id in web_downloads.keys():
		_drop_web_download(task_id)
	_staging_cleared = false
	if _pending_search:
		_show_connection_message()


func on_categories_changed() -> void:
	if is_node_ready():
		_fill_categories()


func has_pending_work() -> bool:
	if _searching or _download_posts > 0 or not _lookup_id.is_empty() or not web_downloads.is_empty():
		return true
	if _thumbs_missing > 0 and Time.get_ticks_msec() < _thumbs_deadline:
		return true
	for base_id in downloads:
		if downloads[base_id].status in ACTIVE_DOWNLOAD:
			return true
	return false


func handle_task(task: Dictionary) -> void:
	match task.get("task_type"):
		"search":
			_handle_search_task(task)
		"thumbnail_download":
			_handle_thumbnail_task(task)
		"asset_download":
			_handle_download_task(task)


## Unfinished tasks are reported on every poll, so a download missing from a
## report is gone, e.g. cancelled in the Client. [param reported] holds the
## report's task ids.
func drop_vanished_downloads(reported: Dictionary) -> void:
	if not is_node_ready():
		return
	for task_id in web_downloads.keys():
		if not reported.has(task_id):
			_drop_web_download(task_id)
	# Once the report shows which downloads still run, clear the rest.
	if not _staging_cleared:
		_staging_cleared = true
		var keep := {}
		for entry in _download_entries():
			keep[entry.folder] = true
		var cleared := GalleryApi.clear_staging(plugin.absolute_download_path, keep)
		if cleared > 0:
			plugin.bk_log(plugin.LogLevel.VERBOSE, "Deleted %d unfinished downloads" % cleared)
	for base_id in downloads:
		var dl: Dictionary = downloads[base_id]
		if dl.get("reported", false) and dl.status in ACTIVE_DOWNLOAD and not reported.has(dl.task_id):
			dl.status = "error"
			dl.message = "Cancelled"
			_refresh_download(base_id)


## Gallery and Send to Godot downloads in progress.
func active_download_count() -> int:
	var count := web_downloads.size()
	for base_id in downloads:
		if downloads[base_id].status in ACTIVE_DOWNLOAD:
			count += 1
	return count


# MARK: search

func request_search(new_page: int = 1, force: bool = false) -> void:
	page = new_page
	if not _is_connected():
		_pending_search = true
		_search_seq += 1
		_searching = false
		_set_busy(false)
		_clear_results()
		_show_connection_message()
		return
	_run_search(force)


func _run_search(force: bool = true) -> void:
	var asset_type := _asset_type()
	var url := GalleryApi.build_search_url(plugin.SERVER, _browse_text(), asset_type,
		_category_slug(), _sort(), free_check.button_pressed,
		asset_type == "model" and plugin.model_format != "blend", page, PAGE_SIZE, plugin.get_addon_version())
	if url == _search_url and _search_error.is_empty() and not force:
		return
	_pending_search = false
	_search_seq += 1
	var seq := _search_seq
	_search_url = url
	_search_text = _browse_text().strip_edges()
	_search_error = ""
	_search_task_id = ""
	_searching = true
	_early_search_tasks.clear()
	# Like the Asset Store, keep the current page dimmed until results arrive.
	message_box.hide()
	_set_busy(true)
	plugin.update_poll_rate()

	var tempdir := GalleryApi.search_temp_dir(plugin.client_data_dir, asset_type)
	var response: Array = await GalleryApi.search(self, plugin.port, plugin.CLIENT_API_VERSION,
		url, asset_type, tempdir, PAGE_SIZE, plugin.get_addon_version(), plugin.auth.api_key())
	if seq != _search_seq:
		return
	if response[0].is_empty():
		_search_failed(response[1])
		return
	_search_task_id = response[0]
	var early = _early_search_tasks.get(_search_task_id)
	_early_search_tasks.clear()
	if early:
		_handle_search_task(early)


func _handle_search_task(task: Dictionary) -> void:
	var status: String = task.get("status", "")
	if not status in ["finished", "error"]:
		return
	var task_id: String = task.get("task_id", "")
	if _handle_lookup_task(task):
		return
	if task_id != _search_task_id:
		if _searching and _search_task_id.is_empty():
			_early_search_tasks[task_id] = task
		return
	_searching = false
	_set_busy(false)
	if status == "error":
		_search_failed(str(task.get("message", "")))
		return
	var result = task.get("result")
	if not result is Dictionary:
		_search_failed("unexpected search result")
		return
	count = int(result.get("count", 0))
	results = result.get("results", []) if result.get("results") is Array else []
	_show_results()


func _search_failed(message: String) -> void:
	_searching = false
	_set_busy(false)
	_search_error = message if message else "unknown error"
	plugin.bk_log(plugin.LogLevel.WARNING, "Search failed: %s" % _search_error)
	_clear_results()
	_show_message("Search failed: %s" % _search_error, "Retry", func(): request_search(page, true))


func _clear_results() -> void:
	items.clear()
	for child in grid.get_children():
		grid.remove_child(child)
		child.queue_free()
	_page_count = 0
	_update_pages()
	_thumbs_missing = 0


func _show_results() -> void:
	_clear_results()
	if results.is_empty():
		if _search_text:
			_show_message("No results for \"%s\"." % _search_text)
		else:
			_show_message("No assets match the selected filters.")
	else:
		message_box.hide()

	_page_count = GalleryApi.page_count(count, PAGE_SIZE)
	_update_pages()

	for asset in results:
		if not asset is Dictionary:
			continue
		var base_id := str(asset.get("assetBaseId", ""))
		var item = gallery_item_scene.instantiate()
		grid.add_child(item)
		item.setup(asset)
		item.selected.connect(_open_details)
		item.set_downloaded(is_downloaded(asset))
		item.set_download(downloads.get(base_id, {}))
		items[base_id] = item
		var thumbs: Dictionary = thumb_cache.get(base_id, {})
		if thumbs.has("small"):
			item.set_thumbnail(GalleryApi.load_texture(thumbs.small))
		else:
			_thumbs_missing += 1
			item.expect_thumbnail(THUMBS_WAIT_MS / 1000.0)
		if not thumbs.has("full"):
			_thumbs_missing += 1
	_thumbs_deadline = Time.get_ticks_msec() + THUMBS_WAIT_MS
	_update_columns()
	# canDownload depends on the account, e.g. after logging in from the dialog.
	if details.visible:
		var open_id := str(details.asset.get("assetBaseId", ""))
		for asset in results:
			if asset is Dictionary and str(asset.get("assetBaseId", "")) == open_id:
				details.asset = asset
				details.refresh_download()
	if _project_mode:
		_other_scroll = 0
	else:
		scroll.scroll_vertical = 0


func _update_pages() -> void:
	# Show as many page numbers as fit, at most the Asset Store's 11.
	var edscale := EditorInterface.get_editor_scale()
	var available := scroll.size.x - border.get_theme_stylebox("panel").get_minimum_size().x
	var window := int(10 / edscale)
	while true:
		_make_pages(top_pages, _page_count, window)
		if window <= 0 or top_pages.get_combined_minimum_size().x <= available:
			break
		window -= 2
	_make_pages(bottom_pages, _page_count, maxi(window, 0))


func _make_pages(container: HBoxContainer, page_count: int, window: int) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()
	if page_count < 2:
		container.hide()
		return
	container.show()
	var edscale := EditorInterface.get_editor_scale()
	container.add_theme_constant_override("separation", int(5 * edscale))
	var from := maxi(1, page - window / 2)
	var to := mini(page_count, from + window)
	from = maxi(1, to - window)

	var spacer := Control.new()
	spacer.size_flags_horizontal = SIZE_EXPAND_FILL
	container.add_child(spacer)
	container.add_child(_page_button("", "BackStart" if has_theme_icon("BackStart", "EditorIcons") else "PageFirst", "First", 1, page != 1))
	container.add_child(_page_button("", "Back", "Previous", page - 1, page > 1))
	container.add_child(VSeparator.new())
	for i in range(from, to + 1):
		container.add_child(_page_button(" %d " % i, "", "", i, i != page))
	container.add_child(VSeparator.new())
	container.add_child(_page_button("", "Forward", "Next", page + 1, page < page_count))
	container.add_child(_page_button("", "ForwardEnd" if has_theme_icon("ForwardEnd", "EditorIcons") else "PageLast", "Last", page_count, page != page_count))
	spacer = Control.new()
	spacer.size_flags_horizontal = SIZE_EXPAND_FILL
	container.add_child(spacer)


func _page_button(text: String, icon_name: String, tooltip: String, target_page: int, enabled: bool) -> Button:
	var button := Button.new()
	button.text = text
	if icon_name:
		button.icon = get_theme_icon(icon_name, "EditorIcons")
	button.tooltip_text = tooltip
	button.theme_type_variation = "PanelBackgroundButton"
	button.disabled = not enabled
	if enabled:
		button.pressed.connect(request_search.bind(target_page, true))
	return button


func _update_columns() -> void:
	var item_width := GalleryItemScript.THUMB_SIZE * EditorInterface.get_editor_scale()
	var separation := grid.get_theme_constant("h_separation")
	var available := scroll.size.x - scroll.get_v_scroll_bar().size.x
	available -= border.get_theme_stylebox("panel").get_minimum_size().x
	grid.columns = maxi(1, int((available + separation) / (item_width + separation)))
	project_grid.columns = grid.columns
	if _page_count > 1:
		_update_pages()


## Dims the results with a spinning logo over them, like the Asset Store
## while it waits for a response.
func _set_busy(busy: bool) -> void:
	_busy = busy
	spinner.rotation = 0
	_update_busy()


## The busy state belongs to the search, so it doesn't show in project mode.
func _update_busy() -> void:
	var busy := _busy and not _project_mode
	scroll.modulate = Color(1, 1, 1, 0.5) if busy else Color.WHITE
	spinner.visible = busy
	set_process(busy)


func _render_logo(px: float) -> Texture2D:
	var svg := FileAccess.get_file_as_string(plugin.LOGO_PATH)
	var image := Image.new()
	if svg.is_empty() or image.load_svg_from_string(svg, px / 320.0) != OK:
		return null
	return ImageTexture.create_from_image(image)


func _show_message(text: String, button_text: String = "", action: Callable = Callable()) -> void:
	message_label.text = text
	message_button.text = button_text
	message_button.visible = not button_text.is_empty()
	_message_action = action
	message_box.show()


func _on_message_button_pressed() -> void:
	if _message_action.is_valid():
		_message_action.call()


func _show_connection_message() -> void:
	if plugin.state == plugin.State.DISABLED:
		_show_message("Blendkit Client is disabled.", "Enable", plugin.set_client_enabled.bind(true))
	elif plugin.state == plugin.State.FAILED:
		_show_message("Blendkit Client failed: %s" % plugin.fail_reason, "Retry", plugin.restart_client)
	else:
		_show_message("Connecting to Blendkit Client…")


# MARK: filters

func _asset_type() -> String:
	return GalleryApi.ASSET_TYPES[maxi(0, type_option.selected)]


func _sort() -> String:
	return GalleryApi.SORTS[maxi(0, sort_option.selected)][0]


func _category_slug() -> String:
	if category_option.selected < 0:
		return ""
	return str(category_option.get_item_metadata(category_option.selected))


func _fill_categories() -> void:
	var selected := _category_slug()
	category_option.clear()
	category_option.add_item("All")
	category_option.set_item_metadata(0, "")
	for top in plugin.categories:
		if not top is Dictionary or top.get("slug") != _asset_type():
			continue
		for child in top.get("children", []):
			if child is Dictionary and child.get("active", true):
				category_option.add_item(str(child.get("name", child.get("slug", ""))))
				category_option.set_item_metadata(category_option.item_count - 1, str(child.get("slug", "")))
	category_option.select(0)
	for i in category_option.item_count:
		if category_option.get_item_metadata(i) == selected:
			category_option.select(i)
	category_option.disabled = category_option.item_count < 2


func _fetch_categories() -> void:
	if _fetching_categories or not _is_connected() or not plugin.categories.is_empty():
		return
	_fetching_categories = true
	var categories: Array = await GalleryApi.fetch_categories(self, plugin.port, plugin.CLIENT_API_VERSION, plugin.SERVER)
	_fetching_categories = false
	if not categories.is_empty() and plugin.categories.is_empty():
		plugin.categories = categories
		_fill_categories()


## Only models have glTF.
func _update_type_filters() -> void:
	format_option.get_parent().visible = _asset_type() == "model"


func _on_sort_selected(index: int) -> void:
	_set_meta("gallery_sort", GalleryApi.SORTS[index][0])
	request_search()


func _on_type_selected(index: int) -> void:
	_set_meta("gallery_type", GalleryApi.ASSET_TYPES[index])
	_update_type_filters()
	category_option.select(0)
	_fill_categories()
	request_search()


func _on_filter_toggled(pressed: bool, meta_key: String) -> void:
	_set_meta(meta_key, pressed)
	request_search()


## The Format dropdown is the Model Format setting. glTF shows only models
## with glTF, so search again.
func _on_model_format_changed() -> void:
	format_option.select(maxi(0, plugin.MODEL_FORMATS.map(func(f): return f[0]).find(plugin.model_format)))
	if _search_started:
		request_search()


## Results depend on the account (canDownload), so search again.
func _on_account_changed() -> void:
	if _search_started:
		request_search(page, true)


func _on_tag_selected(tag: String) -> void:
	details.hide()
	search_edit.text = tag
	_on_search_text_submitted(tag)


static func _get_meta(key: String, default: Variant) -> Variant:
	return EditorInterface.get_editor_settings().get_project_metadata("blendkit", key, default)


static func _set_meta(key: String, value: Variant) -> void:
	EditorInterface.get_editor_settings().set_project_metadata("blendkit", key, value)


# MARK: project assets

func _browse_text() -> String:
	return _other_text if _project_mode else search_edit.text


## Searching Blendkit waits for Enter, like the Blender add-on, except the
## clear button, which shows the default results right away.
func _on_search_text_changed(text: String) -> void:
	if _project_mode:
		_filter_project()
	elif text.is_empty() and _search_mouse_edit:
		request_search()


## Runs before the box handles the event, so the text change that follows
## knows whether it came from the keyboard or the mouse.
func _on_search_gui_input(event: InputEvent) -> void:
	if event is InputEventKey or event is InputEventMouseButton:
		_search_mouse_edit = event is InputEventMouseButton


func _on_search_text_submitted(_text: String) -> void:
	if _project_mode:
		_filter_project()
	else:
		request_search()


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
	body.visible = not pressed
	project_body.visible = pressed
	_update_busy()
	if pressed:
		_refresh_project()
	search_edit.grab_focus()
	# The scroll range follows the new content after layout.
	var restore := _other_scroll
	_other_scroll = scroll_position
	await get_tree().process_frame
	scroll.scroll_vertical = restore


func _on_project_files_changed() -> void:
	if _project_mode:
		_refresh_project()


## Rescan the download directory and rebuild the tiles if anything changed.
## Downloads in progress come first.
func _refresh_project() -> void:
	var entries := _download_entries()
	entries.append_array(project.scan(plugin.absolute_download_path))
	var signature := str(entries.map(func(e): return [e.id, e.time, e.known, e.thumbnail, e.asset.get("name", "")]))
	if signature != _project_signature:
		_project_signature = signature
		for child in project_grid.get_children():
			project_grid.remove_child(child)
			child.queue_free()
		_project_entries = entries
		_project_download_items.clear()
		for entry in entries:
			var item = gallery_item_scene.instantiate()
			project_grid.add_child(item)
			item.setup(entry.asset)
			item.selected.connect(func(_asset): _open_project_details(entry))
			var texture := GalleryApi.load_texture(entry.thumbnail)
			if texture:
				item.set_thumbnail(texture)
			else:
				item.set_thumbnail_failed()
			if entry.has("download"):
				item.set_download(entry.download)
				_project_download_items[entry.id] = item
			entry.item = item
		_update_columns()
	_filter_project()
	for entry in _project_entries:
		if not entry.has("download") and not entry.known and not _lookup_failed.has(entry.id) and entry.id != _lookup_id:
			_lookup_queue[entry.id] = entry.asset.assetType
	_next_lookup()


## Project entries for the downloads in progress, like ProjectAssets.scan()
## with the download and its staging folder.
func _download_entries() -> Array:
	var entries: Array = []
	for base_id in downloads:
		var dl: Dictionary = downloads[base_id]
		if dl.status in ACTIVE_DOWNLOAD:
			entries.append({"id": base_id, "file_path": "", "time": -1, "asset": dl.asset, "known": true,
				"thumbnail": thumb_cache.get(base_id, {}).get("small", ""), "download": dl,
				"folder": GalleryApi.asset_download_dir(GalleryApi.staging_path(plugin.absolute_download_path), dl.asset)})
	for task_id in web_downloads:
		var web: Dictionary = web_downloads[task_id]
		var known: bool = not web.id.is_empty() and project.has(web.id)
		entries.append({"id": task_id, "file_path": "", "time": -1, "asset": _web_download_asset(web),
			"known": known, "thumbnail": project.thumbnail(web.id) if known else "", "download": web,
			"folder": web.folder})
	return entries


func _filter_project() -> void:
	var shown := 0
	for entry in _project_entries:
		entry.item.visible = ProjectAssets.matches(entry, search_edit.text)
		if entry.item.visible:
			shown += 1
	project_message.visible = shown == 0
	project_grid.visible = shown > 0
	# The message and Browse Blendkit sit in the middle, otherwise the button
	# follows the tiles.
	project_body.alignment = BoxContainer.ALIGNMENT_CENTER if shown == 0 else BoxContainer.ALIGNMENT_BEGIN
	if _project_entries.is_empty():
		project_message.text = "No assets downloaded yet to %s" % plugin.download_dir
	elif shown == 0:
		project_message.text = "No downloaded assets match \"%s\"." % search_edit.text.strip_edges()


## A finished download this gallery didn't start, e.g. Send to Godot.
func _on_downloaded_elsewhere(file_path: String) -> void:
	if file_path.is_empty():
		return
	var folder := file_path.get_base_dir()
	for base_id in items:
		if GalleryApi.asset_download_dir(plugin.absolute_download_path, items[base_id].asset) == folder:
			items[base_id].set_downloaded(true)
	if ProjectSettings.localize_path(file_path).begins_with("res://"):
		EditorInterface.get_resource_filesystem().scan()
	_on_project_files_changed()


# MARK: project asset lookups

## Look up the next unknown asset folder on Blendkit, one at a time. The
## search task also downloads the thumbnail, see _handle_thumbnail_task().
func _next_lookup() -> void:
	if not _lookup_id.is_empty() or _lookup_queue.is_empty() or not _is_connected():
		return
	var id: String = _lookup_queue.keys()[0]
	var asset_type: String = _lookup_queue[id]
	_lookup_queue.erase(id)
	if project.has(id):
		_next_lookup()
		return
	_lookup_id = id
	_lookup_type = asset_type
	_lookup_posting = true
	_early_lookup_tasks.clear()
	plugin.update_poll_rate()
	var url := GalleryApi.build_lookup_url(plugin.SERVER, id, plugin.get_addon_version())
	var tempdir := GalleryApi.search_temp_dir(plugin.client_data_dir, asset_type)
	var response: Array = await GalleryApi.search(self, plugin.port, plugin.CLIENT_API_VERSION,
		url, asset_type, tempdir, 1, plugin.get_addon_version(), plugin.auth.api_key())
	_lookup_posting = false
	if _lookup_id != id:
		return # reset by a disconnect meanwhile
	if response[0].is_empty():
		plugin.bk_log(plugin.LogLevel.DEBUG, "Asset lookup failed: %s" % response[1])
		_finish_lookup({})
		return
	_lookup_task_id = response[0]
	var early = _early_lookup_tasks.get(_lookup_task_id)
	_early_lookup_tasks.clear()
	if early:
		_finish_lookup(early)


## Returns whether the search task was a lookup.
func _handle_lookup_task(task: Dictionary) -> bool:
	var task_id: String = task.get("task_id", "")
	if not _lookup_task_id.is_empty() and task_id == _lookup_task_id:
		_finish_lookup(task)
		return true
	if _lookup_posting:
		# It may also be the gallery's search; whichever POST returns it takes it.
		_early_lookup_tasks[task_id] = task
	return false


func _finish_lookup(task: Dictionary) -> void:
	var id := _lookup_id
	_lookup_id = ""
	_lookup_task_id = ""
	var result = task.get("result")
	var results = result.get("results") if result is Dictionary else null
	if task.get("status") == "finished" and results is Array and not results.is_empty() \
			and results[0] is Dictionary and str(results[0].get("id", "")) == id:
		var asset: Dictionary = results[0]
		project.store(asset, thumb_cache.get(str(asset.get("assetBaseId", "")), {}).get("small", ""))
		_on_project_files_changed()
	else:
		plugin.bk_log(plugin.LogLevel.VERBOSE, "Asset %s not found on Blendkit" % id)
		_lookup_failed[id] = true
	_next_lookup()


# MARK: thumbnails

func _handle_thumbnail_task(task: Dictionary) -> void:
	var status: String = task.get("status", "")
	var data = task.get("data")
	if not status in ["finished", "error"] or not data is Dictionary:
		return
	var base_id := str(data.get("assetBaseId", ""))
	var type := str(data.get("thumbnail_type", ""))
	if items.has(base_id) and type in ["small", "full"] and _thumbs_missing > 0:
		_thumbs_missing -= 1
	if status == "error":
		plugin.bk_log(plugin.LogLevel.DEBUG, "Thumbnail failed: %s" % task.get("message", ""))
		if type == "small" and items.has(base_id):
			items[base_id].set_thumbnail_failed()
		return
	var path := str(data.get("image_path", ""))
	if not thumb_cache.has(base_id):
		thumb_cache[base_id] = {}
	thumb_cache[base_id][type] = path
	if type == "small" and items.has(base_id):
		items[base_id].set_thumbnail(GalleryApi.load_texture(path))
	if type == "small" and project.add_thumbnail(base_id, path):
		_on_project_files_changed()
	if details.visible and str(details.asset.get("assetBaseId", "")) == base_id:
		details.on_thumbnail(type, GalleryApi.load_texture(path))


# MARK: details and downloads

func _open_details(asset: Dictionary) -> void:
	details.show_asset(asset, thumb_cache.get(str(asset.get("assetBaseId", "")), {}))


func _open_project_details(entry: Dictionary) -> void:
	if entry.has("download"):
		# Send to Godot downloads have no details until they finish.
		if entry.download.has("asset"):
			_open_details(entry.asset)
		return
	var thumbs: Dictionary = thumb_cache.get(str(entry.asset.get("assetBaseId", "")), {}).duplicate()
	if entry.thumbnail and not thumbs.has("small"):
		thumbs.small = entry.thumbnail
	details.show_asset(entry.asset, thumbs, entry.file_path)


func get_download(base_id: String) -> Dictionary:
	return downloads.get(base_id, {})


func is_downloaded(asset: Dictionary) -> bool:
	var dir := GalleryApi.asset_download_dir(plugin.absolute_download_path, asset)
	return DirAccess.dir_exists_absolute(dir) and not DirAccess.get_files_at(dir).is_empty()


func _on_download_requested(asset: Dictionary, file_type: String) -> void:
	var base_id := str(asset.get("assetBaseId", ""))
	if downloads.has(base_id) and downloads[base_id].status in ACTIVE_DOWNLOAD:
		return
	var dl := {"task_id": "", "status": "posting", "progress": 0, "message": "Starting download",
		"file_type": file_type, "file_path": "", "asset": asset}
	downloads[base_id] = dl
	if not _is_connected():
		dl.status = "error"
		dl.message = "Blendkit Client is not connected"
		_refresh_download(base_id)
		return
	_refresh_download(base_id)
	_download_posts += 1
	plugin.update_poll_rate()
	GalleryApi.ensure_staging(plugin.absolute_download_path)
	var response: Array = await GalleryApi.download(self, plugin.port, plugin.CLIENT_API_VERSION,
		asset, file_type, GalleryApi.staging_path(plugin.absolute_download_path), plugin.get_addon_version(), plugin.auth.api_key())
	_download_posts -= 1
	if not is_same(downloads.get(base_id), dl) or dl.status != "posting":
		return # reset by a disconnect meanwhile
	if response[0].is_empty():
		dl.status = "error"
		dl.message = response[1]
		_refresh_download(base_id)
		return
	dl.task_id = response[0]
	dl.status = "created"
	# Its tasks may have been taken for Send to Godot while the POST ran.
	_drop_web_download(dl.task_id)
	var early = _early_download_tasks.get(dl.task_id)
	_early_download_tasks.erase(dl.task_id)
	if _download_posts == 0:
		_early_download_tasks.clear()
	if early:
		_apply_download_task(base_id, early)
	else:
		_refresh_download(base_id)


func _handle_download_task(task: Dictionary) -> void:
	var task_id: String = task.get("task_id", "")
	for base_id in downloads:
		if downloads[base_id].task_id == task_id:
			_apply_download_task(base_id, task)
			return
	if _download_posts > 0:
		_early_download_tasks[task_id] = task
	# Send to Godot on blendkit.com, or a download whose POST hasn't returned
	# yet (handled again when it does).
	_handle_web_download_task(task)
	if task.get("status") == "finished":
		var path := GalleryApi.finish_download(GalleryApi.task_file_path(task))
		if path.is_empty():
			plugin.bk_log(plugin.LogLevel.WARNING, "Could not move %s into %s" % [GalleryApi.task_file_path(task), plugin.download_dir])
		_on_downloaded_elsewhere(path)


func _apply_download_task(base_id: String, task: Dictionary) -> void:
	var dl: Dictionary = downloads[base_id]
	if not dl.status in ACTIVE_DOWNLOAD:
		return
	var status: String = task.get("status", "")
	dl.reported = true
	match status:
		"created", "progress":
			dl.status = status
			dl.progress = int(task.get("progress", 0))
			dl.message = str(task.get("message", ""))
		"finished":
			dl.file_path = GalleryApi.finish_download(GalleryApi.task_file_path(task))
			if dl.file_path.is_empty():
				dl.status = "error"
				dl.message = "Could not move the download into %s" % plugin.download_dir
				_refresh_download(base_id)
				return
			dl.status = "finished"
			dl.progress = 100
			dl.message = ""
			if items.has(base_id):
				items[base_id].set_downloaded(true)
			project.store(dl.asset, thumb_cache.get(base_id, {}).get("small", ""))
			if ProjectSettings.localize_path(dl.file_path).begins_with("res://"):
				EditorInterface.get_resource_filesystem().scan()
			_on_project_files_changed()
		"error", "cancelled":
			dl.status = "error"
			dl.message = "Cancelled" if status == "cancelled" else str(task.get("message", ""))
	_refresh_download(base_id)


func _on_cancel_requested(task_id: String) -> void:
	await GalleryApi.cancel_download(self, plugin.port, plugin.CLIENT_API_VERSION, task_id)
	# A cancelled task can disappear without a final report.
	for base_id in downloads:
		var dl: Dictionary = downloads[base_id]
		if dl.task_id == task_id and dl.status in ACTIVE_DOWNLOAD:
			dl.status = "error"
			dl.message = "Cancelled"
			_refresh_download(base_id)


## Show the download state on the asset's tiles and, when open, its details.
func _refresh_download(base_id: String) -> void:
	var dl: Dictionary = downloads.get(base_id, {})
	if items.has(base_id):
		items[base_id].set_download(dl)
	if details.visible and str(details.asset.get("assetBaseId", "")) == base_id:
		details.refresh_download()
	if _project_download_items.has(base_id) != (dl.get("status", "") in ACTIVE_DOWNLOAD):
		_on_project_files_changed()
	elif _project_download_items.has(base_id):
		_project_download_items[base_id].set_download(dl)
	_update_download_badge()


# MARK: Send to Godot downloads

func _handle_web_download_task(task: Dictionary) -> void:
	var task_id: String = task.get("task_id", "")
	var status: String = task.get("status", "")
	if not status in ACTIVE_DOWNLOAD:
		_drop_web_download(task_id)
		return
	var changed := not web_downloads.has(task_id)
	if changed:
		web_downloads[task_id] = {"task_id": task_id, "folder": "", "id": "", "asset_type": "",
			"since": int(Time.get_unix_time_from_system()) - WEB_FOLDER_SLACK}
		# The Client made the staging folder, but not its .gitignore.
		GalleryApi.ensure_staging(plugin.absolute_download_path)
		plugin.update_poll_rate()
	var web: Dictionary = web_downloads[task_id]
	web.status = status
	web.progress = int(task.get("progress", 0))
	web.message = str(task.get("message", ""))
	if web.folder.is_empty() and Time.get_unix_time_from_system() < web.since + WEB_FOLDER_SLACK + WEB_FOLDER_SEARCH:
		changed = _find_web_download_folder(web) or changed
	if changed:
		_on_project_files_changed()
	elif _project_download_items.has(task_id):
		_project_download_items[task_id].set_download(web)
	_update_download_badge()


func _drop_web_download(task_id: String) -> void:
	if web_downloads.erase(task_id):
		_on_project_files_changed()
		_update_download_badge()


## Guess the asset the Send to Godot task downloads from the folder that
## changed last, and look it up for its name and thumbnail. Returns whether
## a folder was found.
func _find_web_download_folder(web: Dictionary) -> bool:
	var taken := {}
	for entry in _download_entries():
		if not entry.folder.is_empty():
			taken[entry.folder] = true
	var found := ProjectAssets.recent_download_folder(GalleryApi.staging_path(plugin.absolute_download_path), web.since, taken)
	if found.is_empty():
		return false
	web.merge(found, true)
	if not project.has(web.id) and not _lookup_failed.has(web.id) and web.id != _lookup_id:
		_lookup_queue[web.id] = web.asset_type
		_next_lookup()
	return true


func _web_download_asset(web: Dictionary) -> Dictionary:
	if web.id.is_empty():
		return {"name": WEB_DOWNLOAD_NAME}
	if project.has(web.id):
		return project.get_asset(web.id)
	var file := ProjectAssets.main_file(web.folder)
	return {"id": web.id, "name": ProjectAssets.placeholder_name(file if file else web.folder),
		"assetType": web.asset_type}


func _update_download_badge() -> void:
	var count := active_download_count()
	_download_badge.text = str(count)
	_download_badge.visible = count > 0
	project_toggle.tooltip_text = "Show assets downloaded to this project"
	if count > 0:
		project_toggle.tooltip_text += "\n%d %s in progress" % [count, "download" if count == 1 else "downloads"]


func _is_connected() -> bool:
	return plugin != null and plugin.state == plugin.State.CONNECTED
