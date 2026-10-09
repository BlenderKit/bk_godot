@tool
extends VBoxContainer
## The Blendkit search of the gallery: filters, paged results and their
## thumbnails. Works like the Asset Store.

const GalleryApi = preload("res://addons/blendkit/ui/gallery/gallery_api.gd")
const ClientTasks = preload("res://addons/blendkit/ui/gallery/client_tasks.gd")
const gallery_item_scene = preload("res://addons/blendkit/ui/gallery/gallery_item.tscn")

const PAGE_SIZE := 30
## How long to keep polling fast for thumbnails after results arrive. Tiles
## still without one then show their asset type icon.
const THUMBS_WAIT_MS := 20000
## Short Model Format labels for the filter row.
const FORMAT_LABELS := {"blend": "Blender (.blend)", "gltf_godot": "glTF (.glb)"}
const SEARCH_TASK := "search"

@onready var filter_row: HFlowContainer = %FilterRow
@onready var sort_option: OptionButton = %SortOption
@onready var type_option: OptionButton = %TypeOption
@onready var category_option: OptionButton = %CategoryOption
@onready var free_check: CheckBox = %FreeCheck
@onready var format_option: OptionButton = %FormatOption
@onready var message_box: VBoxContainer = %MessageBox
@onready var message_label: Label = %MessageLabel
@onready var message_button: Button = %MessageButton
@onready var top_pages: HBoxContainer = %TopPages
@onready var grid: GridContainer = %Grid
@onready var bottom_pages: HBoxContainer = %BottomPages
@onready var categories_timer: Timer = %CategoriesTimer

var gallery: Node
var plugin: EditorPlugin
var page := 1
var count := 0
var results: Array = []
## assetBaseId -> GalleryItem on the current page.
var items: Dictionary = {}

var _started := false
var _pending_search := false
var _search_url := ""
var _search_text := ""
var _search_error := ""
var _thumbs_missing := 0
var _thumbs_deadline := 0
var _fetching_categories := false
var _message_action := Callable()
var _page_count := 0
## [page, page count] the page buttons were made for.
var _pages_made: Array = []


## Called by the gallery once the plugin is known.
func setup(new_gallery: Node) -> void:
	gallery = new_gallery
	plugin = gallery.plugin
	# Spacing follows the Asset Store (EditorAssetLibrary).
	var edscale := EditorInterface.get_editor_scale()
	add_theme_constant_override("separation", int(20 * edscale))
	# Filters share one line when they fit and wrap otherwise.
	filter_row.add_theme_constant_override("h_separation", int(12 * edscale))
	filter_row.add_theme_constant_override("v_separation", int(6 * edscale))
	category_option.custom_minimum_size.x = 140 * edscale
	grid.add_theme_constant_override("h_separation", int(10 * edscale))
	grid.add_theme_constant_override("v_separation", int(10 * edscale))

	for sort in GalleryApi.SORTS:
		sort_option.add_item(sort[1])
	for asset_type in GalleryApi.ASSET_TYPES:
		type_option.add_item(GalleryApi.ASSET_TYPE_LABELS[asset_type])
	for format in plugin.MODEL_FORMATS:
		format_option.add_item(FORMAT_LABELS.get(format[0], format[1]))
	sort_option.select(GalleryApi.option_index(GalleryApi.SORTS, _get_meta("gallery_sort", "relevance")))
	type_option.select(maxi(0, GalleryApi.ASSET_TYPES.find(_get_meta("gallery_type", "model"))))
	free_check.button_pressed = _get_meta("gallery_free", false)
	_on_model_format_changed()
	_update_type_filters()
	fill_categories()

	sort_option.item_selected.connect(_on_sort_selected)
	type_option.item_selected.connect(_on_type_selected)
	category_option.item_selected.connect(func(_i): request_search())
	free_check.toggled.connect(_on_filter_toggled.bind("gallery_free"))
	format_option.item_selected.connect(func(i): plugin.set_model_format(plugin.MODEL_FORMATS[i][0]))
	plugin.model_format_changed.connect(_on_model_format_changed)
	plugin.auth.account_changed.connect(_on_account_changed)
	message_button.pressed.connect(_on_message_button_pressed)
	categories_timer.timeout.connect(_fetch_categories)
	gallery.downloads.download_changed.connect(_on_download_changed)
	gallery.downloads.download_finished.connect(_on_download_finished)
	gallery.downloads.web_download_finished.connect(_on_web_download_finished)


## Page buttons have the theme's icons.
func update_theme() -> void:
	_pages_made = []
	update_pages()


## The first search runs when the tab is first shown.
func on_shown() -> void:
	if not _started:
		_started = true
		request_search()


func has_pending_work() -> bool:
	if gallery.tasks.has(SEARCH_TASK):
		return true
	return _thumbs_missing > 0 and Time.get_ticks_msec() < _thumbs_deadline


# MARK: Client connection

func on_connected() -> void:
	if plugin.categories.is_empty():
		# categories_update comes once per subscription; fetch it if missed
		categories_timer.start()
	if _pending_search:
		_run_search()


## The Client cancels the app's tasks when it unsubscribes, so a running
## search runs again on connect.
func on_disconnected() -> void:
	categories_timer.stop()
	if gallery.tasks.has(SEARCH_TASK):
		_pending_search = true
		gallery.set_busy(false)
		_clear_results()
	_search_url = ""
	update_connection_message()


func update_connection_message() -> void:
	if not _pending_search:
		return
	if plugin.state == plugin.State.DISABLED:
		_show_message("Blendkit Client is disabled.", "Enable", plugin.set_client_enabled.bind(true))
	elif plugin.state == plugin.State.FAILED:
		_show_message("Blendkit Client failed: %s" % plugin.fail_reason, "Retry", plugin.restart_client)
	else:
		_show_message("Connecting to Blendkit Client…")


# MARK: search

func request_search(new_page: int = 1, force: bool = false) -> void:
	page = new_page
	if not plugin.is_client_connected():
		_pending_search = true
		gallery.tasks.forget(SEARCH_TASK)
		gallery.set_busy(false)
		_clear_results()
		update_connection_message()
		return
	_run_search(force)


func _run_search(force: bool = true) -> void:
	var asset_type := _asset_type()
	var text: String = gallery.blendkit_query()
	var url := GalleryApi.build_search_url(plugin.SERVER, text, asset_type,
		_category_slug(), _sort(), free_check.button_pressed,
		asset_type == "model" and plugin.model_format != "blend", page, PAGE_SIZE, plugin.get_addon_version())
	if url == _search_url and _search_error.is_empty() and not force:
		return
	_pending_search = false
	_search_url = url
	_search_text = text.strip_edges()
	_search_error = ""
	# Like the Asset Store, keep the current page dimmed until results arrive.
	message_box.hide()
	gallery.set_busy(true)

	var tempdir := GalleryApi.search_temp_dir(plugin.client_data_dir, asset_type)
	var post := func() -> Array:
		return await GalleryApi.search(self, plugin, url, asset_type, tempdir, PAGE_SIZE)
	var response: Array = await gallery.tasks.start(SEARCH_TASK, post, _on_search_task)
	if response.is_empty():
		return # superseded or disconnected meanwhile
	if response[0].is_empty():
		_search_failed(response[1])


func _on_search_task(task: Dictionary) -> void:
	var status: String = task.get("status", "")
	if not status in ClientTasks.FINAL:
		return
	gallery.set_busy(false)
	if status != "finished":
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
	gallery.set_busy(false)
	_search_error = message if message else "unknown error"
	plugin.log_warning("Search failed: %s" % _search_error)
	_clear_results()
	_show_message("Search failed: %s" % _search_error, "Retry", func(): request_search(page, true))


func _clear_results() -> void:
	items.clear()
	for child in grid.get_children():
		grid.remove_child(child)
		child.queue_free()
	_page_count = 0
	update_pages()
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
	update_pages()

	for asset in results:
		if not asset is Dictionary:
			continue
		var base_id := str(asset.get("assetBaseId", ""))
		var item = gallery_item_scene.instantiate()
		grid.add_child(item)
		item.setup(asset)
		item.selected.connect(gallery.open_details)
		item.set_downloaded(gallery.is_downloaded(asset))
		item.set_download(gallery.downloads.get_download(base_id))
		items[base_id] = item
		var thumbs: Dictionary = gallery.thumb_cache.get(base_id, {})
		if thumbs.has("small"):
			item.set_thumbnail(GalleryApi.load_texture(thumbs.small))
		else:
			_thumbs_missing += 1
		if not thumbs.has("full"):
			_thumbs_missing += 1
	_thumbs_deadline = Time.get_ticks_msec() + THUMBS_WAIT_MS
	get_tree().create_timer(THUMBS_WAIT_MS / 1000.0).timeout.connect(_on_thumbs_timeout.bind(_thumbs_deadline))
	gallery.update_columns()
	# canDownload depends on the account, e.g. after logging in from the dialog.
	var details = gallery.details
	if details.visible:
		var open_id := str(details.asset.get("assetBaseId", ""))
		for asset in results:
			if asset is Dictionary and str(asset.get("assetBaseId", "")) == open_id:
				details.asset = asset
				details.refresh_download()
	gallery.reset_search_scroll()


## A finished or failed thumbnail of an asset; [param path] is "" if it failed.
func on_thumbnail(base_id: String, type: String, path: String) -> void:
	if not items.has(base_id):
		return
	if type in ["small", "full"] and _thumbs_missing > 0:
		_thumbs_missing -= 1
	if type != "small":
		return
	if path:
		items[base_id].set_thumbnail(GalleryApi.load_texture(path))
	else:
		items[base_id].set_thumbnail_failed()


## Thumbnails that didn't arrive in time failed, unless newer results
## replaced the tiles meanwhile.
func _on_thumbs_timeout(deadline: int) -> void:
	if deadline != _thumbs_deadline:
		return
	for item in items.values():
		item.set_thumbnail_failed()


# MARK: pages

## Show as many page numbers as fit, at most the Asset Store's 11. The
## buttons are made once per page, resizing only hides some.
func update_pages() -> void:
	var max_window := int(10 / EditorInterface.get_editor_scale())
	if _pages_made != [page, _page_count]:
		_pages_made = [page, _page_count]
		_make_pages(top_pages, _page_count, max_window)
		_make_pages(bottom_pages, _page_count, max_window)
	if _page_count < 2:
		return
	var available: float = gallery.content_width()
	var window := max_window
	while true:
		_show_page_numbers(top_pages, window)
		if window <= 0 or top_pages.get_combined_minimum_size().x <= available:
			break
		window -= 2
	_show_page_numbers(bottom_pages, maxi(window, 0))


func has_pages() -> bool:
	return _page_count > 1


## First and last page numbers shown for a window around the current page.
func _page_range(window: int) -> Vector2i:
	var to := mini(_page_count, maxi(1, page - window / 2) + window)
	return Vector2i(maxi(1, to - window), to)


func _show_page_numbers(container: HBoxContainer, window: int) -> void:
	var shown := _page_range(window)
	for child in container.get_children():
		if child.has_meta("page"):
			var number: int = child.get_meta("page")
			child.visible = number >= shown.x and number <= shown.y


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
	var shown := _page_range(window)

	var spacer := Control.new()
	spacer.size_flags_horizontal = SIZE_EXPAND_FILL
	container.add_child(spacer)
	container.add_child(_page_button("", "BackStart" if has_theme_icon("BackStart", "EditorIcons") else "PageFirst", "First", 1, page != 1))
	container.add_child(_page_button("", "Back", "Previous", page - 1, page > 1))
	container.add_child(VSeparator.new())
	for i in range(shown.x, shown.y + 1):
		var number := _page_button(" %d " % i, "", "", i, i != page)
		number.set_meta("page", i)
		container.add_child(number)
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


# MARK: message

func _show_message(text: String, button_text: String = "", action: Callable = Callable()) -> void:
	message_label.text = text
	message_button.text = button_text
	message_button.visible = not button_text.is_empty()
	_message_action = action
	message_box.show()


func _on_message_button_pressed() -> void:
	if _message_action.is_valid():
		_message_action.call()


# MARK: filters

func _asset_type() -> String:
	return GalleryApi.ASSET_TYPES[maxi(0, type_option.selected)]


func _sort() -> String:
	return GalleryApi.SORTS[maxi(0, sort_option.selected)][0]


func _category_slug() -> String:
	if category_option.selected < 0:
		return ""
	return str(category_option.get_item_metadata(category_option.selected))


func fill_categories() -> void:
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
	if _fetching_categories or not plugin.is_client_connected() or not plugin.categories.is_empty():
		return
	_fetching_categories = true
	var categories: Array = await GalleryApi.fetch_categories(self, plugin)
	_fetching_categories = false
	if not categories.is_empty() and plugin.categories.is_empty():
		plugin.categories = categories
		fill_categories()


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
	fill_categories()
	request_search()


func _on_filter_toggled(pressed: bool, meta_key: String) -> void:
	_set_meta(meta_key, pressed)
	request_search()


## The Format dropdown is the Model Format setting. glTF shows only models
## with glTF, so search again.
func _on_model_format_changed() -> void:
	format_option.select(GalleryApi.option_index(plugin.MODEL_FORMATS, plugin.model_format))
	if _started:
		request_search()


## Results depend on the account (canDownload), so search again.
func _on_account_changed() -> void:
	if _started:
		request_search(page, true)


static func _get_meta(key: String, default: Variant) -> Variant:
	return EditorInterface.get_editor_settings().get_project_metadata("blendkit", key, default)


static func _set_meta(key: String, value: Variant) -> void:
	EditorInterface.get_editor_settings().set_project_metadata("blendkit", key, value)


# MARK: downloads

func _on_download_changed(id: String) -> void:
	if items.has(id):
		items[id].set_download(gallery.downloads.get_download(id))


func _on_download_finished(base_id: String) -> void:
	if items.has(base_id):
		items[base_id].set_downloaded(true)


## A finished download this gallery didn't start, e.g. Send to Godot.
func _on_web_download_finished(file_path: String) -> void:
	var folder := file_path.get_base_dir()
	for base_id in items:
		if GalleryApi.asset_download_dir(plugin.absolute_download_path, items[base_id].asset) == folder:
			items[base_id].set_downloaded(true)
