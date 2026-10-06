@tool
extends PanelContainer
## Blendkit main-screen tab: search with filters, paged thumbnails and an
## asset details dialog with a Download button. Works like the Asset Store.
##
## The plugin owns the Client connection. It calls handle_task() for search,
## thumbnail and download tasks from its /godot/report poll, and
## on_connection_changed() / on_categories_changed() on updates.

const GalleryApi = preload("res://addons/blendkit/ui/gallery/gallery_api.gd")
const GalleryItemScript = preload("res://addons/blendkit/ui/gallery/gallery_item.gd")
const gallery_item_scene = preload("res://addons/blendkit/ui/gallery/gallery_item.tscn")

const PAGE_SIZE := 30
## How long to keep polling fast for thumbnails after results arrive.
const THUMBS_WAIT_MS := 20000
const ACTIVE_DOWNLOAD := ["posting", "created", "progress"]

@onready var main: VBoxContainer = %Main
@onready var search_edit: LineEdit = %SearchEdit
@onready var client_toggle: CheckButton = %ClientToggle
@onready var account_button: Button = %AccountButton
@onready var sort_option: OptionButton = %SortOption
@onready var type_option: OptionButton = %TypeOption
@onready var category_option: OptionButton = %CategoryOption
@onready var filter_row: HFlowContainer = %FilterRow
@onready var free_check: CheckBox = %FreeCheck
@onready var godot_ready_check: CheckBox = %GodotReadyCheck
@onready var scroll: ScrollContainer = %Scroll
@onready var border: PanelContainer = %Border
@onready var body: VBoxContainer = %Body
@onready var message_box: VBoxContainer = %MessageBox
@onready var message_label: Label = %MessageLabel
@onready var message_button: Button = %MessageButton
@onready var top_pages: HBoxContainer = %TopPages
@onready var grid: GridContainer = %Grid
@onready var bottom_pages: HBoxContainer = %BottomPages
@onready var debounce_timer: Timer = %DebounceTimer
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


func _ready() -> void:
	if plugin == null:
		return
	# Spacing follows the Asset Store (EditorAssetLibrary).
	var edscale := EditorInterface.get_editor_scale()
	main.add_theme_constant_override("separation", int(10 * edscale))
	body.add_theme_constant_override("separation", int(20 * edscale))
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

	for sort in GalleryApi.SORTS:
		sort_option.add_item(sort[1])
	for asset_type in GalleryApi.ASSET_TYPES:
		type_option.add_item(GalleryApi.ASSET_TYPE_LABELS[asset_type])
	sort_option.select(maxi(0, GalleryApi.SORTS.map(func(s): return s[0]).find(_get_meta("gallery_sort", "relevance"))))
	type_option.select(maxi(0, GalleryApi.ASSET_TYPES.find(_get_meta("gallery_type", "model"))))
	free_check.button_pressed = _get_meta("gallery_free", false)
	godot_ready_check.button_pressed = _get_meta("gallery_godot_ready", false)
	_update_type_filters()
	_fill_categories()

	search_edit.text_changed.connect(func(_t): debounce_timer.start())
	search_edit.text_submitted.connect(func(_t): request_search())
	debounce_timer.timeout.connect(request_search)
	sort_option.item_selected.connect(_on_sort_selected)
	type_option.item_selected.connect(_on_type_selected)
	category_option.item_selected.connect(func(_i): request_search())
	free_check.toggled.connect(_on_filter_toggled.bind("gallery_free"))
	godot_ready_check.toggled.connect(_on_filter_toggled.bind("gallery_godot_ready"))
	client_toggle.toggled.connect(_on_client_toggled)
	account_button.setup(plugin)
	plugin.auth.account_changed.connect(_on_account_changed)
	plugin.auth.changed.connect(func():
		if details.visible:
			details.refresh_download())
	message_button.pressed.connect(_on_message_button_pressed)
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


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_VISIBILITY_CHANGED:
			# The first search runs when the tab is first shown.
			if plugin and is_visible_in_tree() and not _search_started:
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
	_update_client_toggle()


# MARK: plugin interface

func on_connection_changed() -> void:
	if not is_node_ready():
		return
	_update_client_toggle()
	account_button.refresh()
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
		return

	# The Client cancels the app's tasks when it unsubscribes.
	categories_timer.stop()
	if _searching:
		_searching = false
		_search_seq += 1
		_pending_search = true
	_search_url = ""
	_search_task_id = ""
	for base_id in downloads:
		var dl: Dictionary = downloads[base_id]
		if dl.status in ACTIVE_DOWNLOAD:
			dl.status = "error"
			dl.message = "Blendkit Client disconnected"
			_refresh_details(base_id)
	if _pending_search:
		_show_connection_message()


func on_categories_changed() -> void:
	if is_node_ready():
		_fill_categories()


func has_pending_work() -> bool:
	if _searching or _download_posts > 0:
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


# MARK: search

func request_search(new_page: int = 1, force: bool = false) -> void:
	page = new_page
	debounce_timer.stop()
	if not _is_connected():
		_pending_search = true
		_search_seq += 1
		_searching = false
		_clear_results()
		_show_connection_message()
		return
	_run_search(force)


func _run_search(force: bool = true) -> void:
	var asset_type := _asset_type()
	var url := GalleryApi.build_search_url(plugin.SERVER, search_edit.text, asset_type,
		_category_slug(), _sort(), free_check.button_pressed,
		godot_ready_check.button_pressed and not godot_ready_check.disabled, page, PAGE_SIZE, plugin.get_addon_version())
	if url == _search_url and _search_error.is_empty() and not force:
		return
	_pending_search = false
	_search_seq += 1
	var seq := _search_seq
	_search_url = url
	_search_text = search_edit.text.strip_edges()
	_search_error = ""
	_search_task_id = ""
	_searching = true
	_early_search_tasks.clear()
	_clear_results()
	_show_message("Searching…")
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
	if task_id != _search_task_id:
		if _searching and _search_task_id.is_empty():
			_early_search_tasks[task_id] = task
		return
	_searching = false
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
		items[base_id] = item
		var thumbs: Dictionary = thumb_cache.get(base_id, {})
		if thumbs.has("small"):
			item.set_thumbnail(GalleryApi.load_texture(thumbs.small))
		else:
			_thumbs_missing += 1
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
		button.pressed.connect(func():
			scroll.scroll_vertical = 0
			request_search(target_page, true))
	return button


func _update_columns() -> void:
	var item_width := GalleryItemScript.THUMB_SIZE * EditorInterface.get_editor_scale()
	var separation := grid.get_theme_constant("h_separation")
	var available := scroll.size.x - scroll.get_v_scroll_bar().size.x
	available -= border.get_theme_stylebox("panel").get_minimum_size().x
	grid.columns = maxi(1, int((available + separation) / (item_width + separation)))
	if _page_count > 1:
		_update_pages()


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
		_show_message("Blendkit Client is disabled.", "Enable", _restart_client)
	elif plugin.state == plugin.State.FAILED:
		_show_message("Blendkit Client failed: %s" % plugin.fail_reason, "Retry", _restart_client)
	else:
		_show_message("Connecting to Blendkit Client…")


## Client switch in the search row: a compact version of the dock's status.
func _update_client_toggle() -> void:
	client_toggle.set_pressed_no_signal(plugin.enabled_check_box.button_pressed)
	client_toggle.icon = plugin.get_state_icon()
	var failed: bool = plugin.state == plugin.State.FAILED
	client_toggle.text = "Client failed" if failed else "Client"
	if failed:
		client_toggle.add_theme_color_override("font_color", get_theme_color("error_color", "Editor"))
	else:
		client_toggle.remove_theme_color_override("font_color")
	var tooltip: String
	if plugin.state == plugin.State.DISABLED:
		tooltip = "Blendkit Client is disabled. Turn it on to search and download assets."
	elif plugin.state == plugin.State.EXPLORING:
		tooltip = "Looking for a running Blendkit Client…"
	elif plugin.state == plugin.State.STARTING:
		tooltip = "Starting Blendkit Client…"
	elif plugin.state == plugin.State.CONNECTED:
		tooltip = "Connected to Blendkit Client v%s." % plugin.connected_client_version
		if plugin.failed_requests > 0:
			tooltip = "Reconnecting to Blendkit Client…"
	else:
		tooltip = "Blendkit Client failed: %s.\nSee the Output panel for details. Turn the Client off and on to retry." % plugin.fail_reason
	client_toggle.tooltip_text = tooltip


func _on_client_toggled(pressed: bool) -> void:
	# The dock checkbox runs the plugin's usual state transitions.
	plugin.enabled_check_box.button_pressed = pressed


func _restart_client() -> void:
	# Toggling the dock checkbox runs the plugin's usual state transitions.
	var check: CheckBox = plugin.enabled_check_box
	if check.button_pressed:
		check.button_pressed = false
	check.button_pressed = true


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


## Godot-ready applies to models only.
func _update_type_filters() -> void:
	godot_ready_check.disabled = _asset_type() != "model"


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


## Results depend on the account (canDownload), so search again.
func _on_account_changed() -> void:
	if _search_started:
		request_search(page, true)


func _on_tag_selected(tag: String) -> void:
	details.hide()
	search_edit.text = tag
	request_search()


static func _get_meta(key: String, default: Variant) -> Variant:
	return EditorInterface.get_editor_settings().get_project_metadata("blendkit", key, default)


static func _set_meta(key: String, value: Variant) -> void:
	EditorInterface.get_editor_settings().set_project_metadata("blendkit", key, value)


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
		return
	var path := str(data.get("image_path", ""))
	if not thumb_cache.has(base_id):
		thumb_cache[base_id] = {}
	thumb_cache[base_id][type] = path
	if type == "small" and items.has(base_id):
		items[base_id].set_thumbnail(GalleryApi.load_texture(path))
	if details.visible and str(details.asset.get("assetBaseId", "")) == base_id:
		details.on_thumbnail(type, GalleryApi.load_texture(path))


# MARK: details and downloads

func _open_details(asset: Dictionary) -> void:
	details.show_asset(asset, thumb_cache.get(str(asset.get("assetBaseId", "")), {}))


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
		_refresh_details(base_id)
		return
	_refresh_details(base_id)
	_download_posts += 1
	plugin.update_poll_rate()
	var response: Array = await GalleryApi.download(self, plugin.port, plugin.CLIENT_API_VERSION,
		asset, file_type, plugin.absolute_download_path, plugin.get_addon_version(), plugin.auth.api_key())
	_download_posts -= 1
	if not is_same(downloads.get(base_id), dl) or dl.status != "posting":
		return # reset by a disconnect meanwhile
	if response[0].is_empty():
		dl.status = "error"
		dl.message = response[1]
		_refresh_details(base_id)
		return
	dl.task_id = response[0]
	dl.status = "created"
	var early = _early_download_tasks.get(dl.task_id)
	_early_download_tasks.erase(dl.task_id)
	if _download_posts == 0:
		_early_download_tasks.clear()
	if early:
		_apply_download_task(base_id, early)
	else:
		_refresh_details(base_id)


func _handle_download_task(task: Dictionary) -> void:
	var task_id: String = task.get("task_id", "")
	for base_id in downloads:
		if downloads[base_id].task_id == task_id:
			_apply_download_task(base_id, task)
			return
	if _download_posts > 0:
		_early_download_tasks[task_id] = task


func _apply_download_task(base_id: String, task: Dictionary) -> void:
	var dl: Dictionary = downloads[base_id]
	if not dl.status in ACTIVE_DOWNLOAD:
		return
	var status: String = task.get("status", "")
	match status:
		"created", "progress":
			dl.status = status
			dl.progress = int(task.get("progress", 0))
			dl.message = str(task.get("message", ""))
		"finished":
			dl.status = "finished"
			dl.progress = 100
			dl.file_path = GalleryApi.task_file_path(task)
			dl.message = ""
			if items.has(base_id):
				items[base_id].set_downloaded(true)
			if ProjectSettings.localize_path(dl.file_path).begins_with("res://"):
				EditorInterface.get_resource_filesystem().scan()
		"error", "cancelled":
			dl.status = "error"
			dl.message = "Cancelled" if status == "cancelled" else str(task.get("message", ""))
	_refresh_details(base_id)


func _on_cancel_requested(task_id: String) -> void:
	await GalleryApi.cancel_download(self, plugin.port, plugin.CLIENT_API_VERSION, task_id)
	# A cancelled task can disappear without a final report.
	for base_id in downloads:
		var dl: Dictionary = downloads[base_id]
		if dl.task_id == task_id and dl.status in ACTIVE_DOWNLOAD:
			dl.status = "error"
			dl.message = "Cancelled"
			_refresh_details(base_id)


func _refresh_details(base_id: String) -> void:
	if details.visible and str(details.asset.get("assetBaseId", "")) == base_id:
		details.refresh_download()


func _is_connected() -> bool:
	return plugin != null and plugin.state == plugin.State.CONNECTED
