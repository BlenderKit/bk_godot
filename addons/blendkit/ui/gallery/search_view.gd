@tool
extends VBoxContainer
## The Blendkit search of the gallery: filters, results and their
## thumbnails. Works like the Asset Store, but the results load more as they
## scroll, like the Blender add-on and blendkit.com.

const ClientBinary = preload("res://addons/blendkit/client_binary.gd")
const ClientConnection = preload("res://addons/blendkit/client_connection.gd")
const GalleryApi = preload("res://addons/blendkit/ui/gallery/gallery_api.gd")
const ClientTasks = preload("res://addons/blendkit/ui/gallery/client_tasks.gd")
const ProjectAssets = preload("res://addons/blendkit/ui/gallery/project_assets.gd")
const gallery_item_scene = preload("res://addons/blendkit/ui/gallery/gallery_item.tscn")
const GalleryItemScript = preload("res://addons/blendkit/ui/gallery/gallery_item.gd")

const PAGE_SIZE := 30
## How long to keep polling fast for thumbnails after results arrive. Tiles
## still without one then show their asset type icon.
const THUMBS_WAIT_MS := 20000
const SEARCH_TASK := "search"
## Load the next page once the results end less than this many screens below
## the view. Cards further away than this let go of their thumbnails.
const MORE_SCREENS := 1.0
## Wait this long after the Polygons range last changed before searching.
const POLYGONS_DELAY := 0.5

@onready var filter_row: HFlowContainer = %FilterRow
@onready var sort_option: OptionButton = %SortOption
@onready var type_option: OptionButton = %TypeOption
@onready var category_option: OptionButton = %CategoryOption
@onready var free_check: CheckBox = %FreeCheck
@onready var procedural_check: CheckBox = %ProceduralCheck
@onready var animated_check: CheckBox = %AnimatedCheck
@onready var rigged_check: CheckBox = %RiggedCheck
@onready var format_option: OptionButton = %FormatOption
@onready var polygon_filter: Button = %PolygonFilter
@onready var author_filter: Button = %AuthorFilter
@onready var message_box: VBoxContainer = %MessageBox
@onready var message_label: Label = %MessageLabel
@onready var message_button: Button = %MessageButton
@onready var grid: GridContainer = %Grid
@onready var more_box: VBoxContainer = %MoreBox
@onready var more_label: Label = %MoreLabel
@onready var more_button: Button = %MoreButton
@onready var categories_timer: Timer = %CategoriesTimer

var gallery: Node
var plugin: EditorPlugin
## Shows only this author's assets when set, until its filter is removed.
var author_id := ""
var count := 0
## The results loaded so far, each asset once.
var results: Array = []
## assetBaseId -> GalleryItem of the results.
var items: Dictionary = {}
## The Client search request, replaced in the tests: post_search(url_query,
## asset_type) returns [task_id, error].
var post_search: Callable = _post_search

var _started := false
var _pending_search := false
var _search_url := ""
var _search_text := ""
var _search_error := ""
var _thumbs_missing := 0
var _thumbs_deadline := 0
var _fetching_categories := false
var _message_action := Callable()
## The server's URL of the next page, "" after the last one.
var _next_url := ""
## Results the server returned so far, repeats included.
var _fetched := 0
var _loading_more := false
## Why the next page failed to load; it loads again on Retry.
var _more_error := ""
var _polygons_timer: Timer


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
	grid.add_theme_constant_override("h_separation", int(GalleryItemScript.GAP * edscale))
	grid.add_theme_constant_override("v_separation", int(GalleryItemScript.GAP * edscale))

	for sort in GalleryApi.SORTS:
		sort_option.add_item(sort[1])
	for asset_type in GalleryApi.ASSET_TYPES:
		type_option.add_item(GalleryApi.ASSET_TYPE_LABELS[asset_type])
	for format in plugin.MODEL_FORMATS:
		format_option.add_item(format[1])
	sort_option.select(GalleryApi.option_index(GalleryApi.SORTS, _get_meta("gallery_sort", "relevance")))
	type_option.select(maxi(0, GalleryApi.ASSET_TYPES.find(_get_meta("gallery_type", "model"))))
	free_check.button_pressed = _get_meta("gallery_free", false)
	animated_check.button_pressed = _get_meta("gallery_animated", false)
	rigged_check.button_pressed = _get_meta("gallery_rigged", false)
	var polygons: Array = _get_meta("gallery_polygons", [0, GalleryApi.NO_LIMIT])
	polygon_filter.setup(polygons[0], polygons[1])
	_polygons_timer = Timer.new()
	_polygons_timer.one_shot = true
	_polygons_timer.wait_time = POLYGONS_DELAY
	add_child(_polygons_timer)
	_on_model_format_changed()
	_update_type_filters()
	fill_categories()

	sort_option.item_selected.connect(_on_sort_selected)
	type_option.item_selected.connect(_on_type_selected)
	category_option.item_selected.connect(func(_i): request_search())
	free_check.toggled.connect(_on_filter_toggled.bind("gallery_free"))
	procedural_check.toggled.connect(func(pressed): _on_filter_toggled(pressed, _procedural_meta_key()))
	animated_check.toggled.connect(_on_filter_toggled.bind("gallery_animated"))
	rigged_check.toggled.connect(_on_filter_toggled.bind("gallery_rigged"))
	polygon_filter.range_changed.connect(_on_polygons_changed)
	author_filter.icon = get_theme_icon("Close", "EditorIcons")
	author_filter.pressed.connect(search_author.bind("", ""))
	_polygons_timer.timeout.connect(request_search)
	# Closing the popup searches right away.
	polygon_filter.closed.connect(func():
		if not _polygons_timer.is_stopped():
			_polygons_timer.stop()
			request_search())
	format_option.item_selected.connect(func(i): plugin.set_model_format(plugin.MODEL_FORMATS[i][0]))
	plugin.model_format_changed.connect(_on_model_format_changed)
	plugin.auth.account_changed.connect(_on_account_changed)
	message_button.pressed.connect(_on_message_button_pressed)
	more_button.pressed.connect(_retry_more)
	var scroll_bar: VScrollBar = gallery.scroll.get_v_scroll_bar()
	# The range changes as the results grow and the view resizes.
	scroll_bar.value_changed.connect(func(_value): on_scrolled())
	scroll_bar.changed.connect(on_scrolled)
	# The grid gets its new height a few layout passes after the results
	# change, later than the scroll range; new results shorter than the old
	# ones may no longer fill the view.
	grid.resized.connect(on_scrolled)
	categories_timer.timeout.connect(_fetch_categories)
	gallery.downloads.download_changed.connect(_on_download_changed)
	gallery.downloads.download_finished.connect(_on_download_finished)
	gallery.downloads.web_download_finished.connect(_on_web_download_finished)
	gallery.downloads.asset_refreshed.connect(_on_asset_refreshed)
	plugin.download_dir_changed.connect(_on_download_dir_changed)


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
	if gallery.categories.is_empty():
		# categories_update comes once per subscription; fetch it if missed
		categories_timer.start()
	if _pending_search:
		_run_search()
	else:
		on_scrolled()


## The Client cancels the app's tasks when it unsubscribes, so a running
## search runs again on connect.
func on_disconnected() -> void:
	categories_timer.stop()
	if _loading_more:
		# The results stay; scrolling loads the next page again.
		_loading_more = false
		_update_more()
	elif gallery.tasks.has(SEARCH_TASK):
		_pending_search = true
		gallery.set_busy(false)
		_clear_results()
	_search_url = ""
	update_connection_message()


func update_connection_message() -> void:
	if not _pending_search:
		return
	if plugin.connection.state == ClientConnection.State.DISABLED:
		_show_message("Blendkit Client is disabled.", "Enable", plugin.set_client_enabled.bind(true))
	elif plugin.connection.state == ClientConnection.State.FAILED:
		_show_message("Blendkit Client failed: %s" % plugin.connection.fail_reason, "Retry", plugin.restart_client)
	else:
		_show_message("Connecting to Blendkit Client…")


# MARK: search

func request_search(force: bool = false) -> void:
	if not plugin.connection.is_client_connected():
		_pending_search = true
		gallery.tasks.forget(SEARCH_TASK)
		gallery.set_busy(false)
		_clear_results()
		update_connection_message()
		return
	_run_search(force)


## Show only the assets by [param new_author_id], or by all authors when empty.
func search_author(new_author_id: String, author_name: String) -> void:
	author_id = new_author_id
	author_filter.text = author_name
	author_filter.get_parent().visible = not author_id.is_empty()
	request_search()


func _run_search(force: bool = true) -> void:
	var asset_type := _asset_type()
	var text: String = gallery.blendkit_query()
	var url := GalleryApi.build_search_url(plugin.SERVER, text, asset_type,
		_category_slug(), _sort(), free_check.button_pressed,
		asset_type == "model" and plugin.model_format != "blend",
		polygon_filter.min_faces, polygon_filter.max_faces, 1, PAGE_SIZE, plugin.get_addon_version(), author_id,
		_flags())
	if url == _search_url and _search_error.is_empty() and not force:
		return
	_pending_search = false
	_search_url = url
	_search_text = text.strip_edges()
	_search_error = ""
	# Like the Asset Store, keep the current results dimmed until new ones
	# arrive.
	message_box.hide()
	_loading_more = false
	_more_error = ""
	_update_more()
	gallery.set_busy(true)
	_start_search(url, false)


## The next page, once the results end near the view. It waits for a search
## running meanwhile, and after a failure for Retry.
func load_more() -> void:
	if _next_url.is_empty() or not _more_error.is_empty() or gallery.tasks.has(SEARCH_TASK) \
			or not plugin.connection.is_client_connected():
		return
	_loading_more = true
	_update_more()
	_start_search(_next_url, true)


## Searches [param url]; [param more] adds the results to those shown.
func _start_search(url: String, more: bool) -> void:
	var response: Array = await gallery.tasks.start(SEARCH_TASK, post_search.bind(url, _asset_type()),
		_on_search_task.bind(more))
	if response.is_empty():
		return # superseded or disconnected meanwhile
	if response[0].is_empty():
		_search_failed(response[1], more)


func _post_search(url: String, asset_type: String) -> Array:
	var tempdir := GalleryApi.search_temp_dir(ClientBinary.get_client_data_dir(), asset_type)
	return await GalleryApi.search(self, plugin, url, asset_type, tempdir, PAGE_SIZE)


func _on_search_task(task: Dictionary, more: bool) -> void:
	var status: String = task.get("status", "")
	if not status in ClientTasks.FINAL:
		return
	if status != "finished":
		_search_failed(str(task.get("message", "")), more)
		return
	var result = task.get("result")
	if not result is Dictionary:
		_search_failed("unexpected search result", more)
		return
	count = int(result.get("count", 0))
	var page: Array = result.get("results", []) if result.get("results") is Array else []
	if more:
		_loading_more = false
		_update_more()
	else:
		gallery.set_busy(false)
		_clear_results()
	_fetched += page.size()
	var next = result.get("next")
	_next_url = next if next is String and _fetched < GalleryApi.MAX_RESULT_WINDOW else ""
	_show_results(page)
	if not more:
		gallery.reset_search_scroll()
	# Repeats or a tall view may leave the results short of the view.
	on_scrolled.call_deferred()


## A failed next page keeps the results, with Retry below them.
func _search_failed(message: String, more: bool = false) -> void:
	var error := message if message else "unknown error"
	plugin.log_warning("Search failed: %s" % error)
	if more:
		_loading_more = false
		_more_error = error
		_update_more()
		return
	gallery.set_busy(false)
	_search_error = error
	_clear_results()
	_show_message("Search failed: %s" % _search_error, "Retry", request_search.bind(true))


func _clear_results() -> void:
	items.clear()
	results = []
	for child in grid.get_children():
		grid.remove_child(child)
		child.queue_free()
	_next_url = ""
	_fetched = 0
	_thumbs_missing = 0


## Adds the cards of a page of results, without the assets shown already.
## Pages are cached on the server at different times, so an asset whose rank
## changed meanwhile can come again.
func _show_results(page: Array) -> void:
	var added: Array = []
	var seen := {}
	for asset in page:
		if asset is Dictionary and not items.has(GalleryApi.base_id(asset)) and not seen.has(GalleryApi.base_id(asset)):
			seen[GalleryApi.base_id(asset)] = true
			added.append(asset)
	results.append_array(added)
	if results.is_empty():
		if _search_text:
			_show_message("No results for \"%s\"." % _search_text)
		else:
			_show_message("No assets match the selected filters.")
	else:
		message_box.hide()

	for asset in added:
		var base_id := GalleryApi.base_id(asset)
		var item = gallery_item_scene.instantiate()
		grid.add_child(item)
		item.setup(asset)
		item.selected.connect(gallery.open_details)
		item.set_downloaded(gallery.is_downloaded(asset))
		item.set_download(gallery.downloads.get_download(base_id))
		items[base_id] = item
		var thumbs: Dictionary = gallery.thumb_cache.get(base_id, {})
		for type in ["small", "full"]:
			if thumbs.has(type):
				item.set_thumbnail(thumbs[type], type)
			else:
				_thumbs_missing += 1
	_thumbs_deadline = Time.get_ticks_msec() + THUMBS_WAIT_MS
	get_tree().create_timer(THUMBS_WAIT_MS / 1000.0).timeout.connect(_on_thumbs_timeout.bind(_thumbs_deadline))
	gallery.update_columns()
	# canDownload depends on the account, e.g. after logging in from the dialog.
	var details = gallery.details
	if details.visible:
		var open_id := GalleryApi.base_id(details.asset)
		for asset in added:
			if GalleryApi.base_id(asset) == open_id:
				details.update_asset(asset)


## A finished or failed thumbnail of an asset; [param path] is "" if it failed.
func on_thumbnail(base_id: String, type: String, path: String) -> void:
	if not items.has(base_id):
		return
	if not type in ["small", "full"]:
		return
	if _thumbs_missing > 0:
		_thumbs_missing -= 1
	if path:
		items[base_id].set_thumbnail(path, type)
	elif type == "small":
		items[base_id].set_thumbnail_failed()


## Thumbnails that didn't arrive in time failed, unless newer results
## replaced the tiles meanwhile.
func _on_thumbs_timeout(deadline: int) -> void:
	if deadline != _thumbs_deadline:
		return
	for item in items.values():
		item.set_thumbnail_failed()


# MARK: scrolling

## Loads the next page once the results end near the view, and lets the
## cards far from it drop their thumbnails, so long results don't keep them
## all decoded.
func on_scrolled() -> void:
	if not is_visible_in_tree() or items.is_empty():
		return
	var scroll: ScrollContainer = gallery.scroll
	var margin := scroll.size.y * MORE_SCREENS
	# The view in the grid's coordinates; scrolling moves both alike.
	var top: float = scroll.scroll_vertical - (grid.global_position.y - gallery.border.global_position.y)
	var bottom: float = top + scroll.size.y
	for item in grid.get_children():
		item.set_near_view(item.position.y + item.size.y >= top - margin and item.position.y <= bottom + margin)
	if grid.size.y < bottom + margin:
		load_more()


## Below the results: the next page loading, or why it failed.
func _update_more() -> void:
	more_box.visible = _loading_more or not _more_error.is_empty()
	more_label.text = "Loading more…" if _more_error.is_empty() else "Loading more failed: %s" % _more_error
	more_button.visible = not _more_error.is_empty()


func _retry_more() -> void:
	_more_error = ""
	load_more()


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
	for top in gallery.categories:
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
	if _fetching_categories or not plugin.connection.is_client_connected() or not gallery.categories.is_empty():
		return
	_fetching_categories = true
	var categories: Array = await GalleryApi.fetch_categories(self, plugin)
	_fetching_categories = false
	if not categories.is_empty() and gallery.categories.is_empty():
		gallery.categories = categories
		fill_categories()


## Only models have glTF; scenes have no polygon count. Hide procedural is
## kept per asset type.
func _update_type_filters() -> void:
	var asset_type := _asset_type()
	format_option.get_parent().visible = asset_type == "model"
	polygon_filter.get_parent().visible = asset_type in GalleryApi.POLYGON_TYPES
	procedural_check.visible = asset_type in GalleryApi.FLAG_TYPES.procedural
	procedural_check.set_pressed_no_signal(_get_meta(_procedural_meta_key(), asset_type == "material"))
	animated_check.visible = asset_type in GalleryApi.FLAG_TYPES.animated
	rigged_check.visible = asset_type in GalleryApi.FLAG_TYPES.rig


## Procedural materials only become a flat color, so materials hide them by
## default. Models are still useful without their textures.
func _procedural_meta_key() -> String:
	return "gallery_hide_procedural_" + _asset_type()


## The yes/no filters for build_search_url, which applies each to its types.
func _flags() -> Dictionary:
	var flags := {}
	if procedural_check.button_pressed:
		flags["procedural"] = false
	if animated_check.button_pressed:
		flags["animated"] = true
	if rigged_check.button_pressed:
		flags["rig"] = true
	return flags


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


## Dragging the range searches once it rests.
func _on_polygons_changed() -> void:
	_set_meta("gallery_polygons", [polygon_filter.min_faces, polygon_filter.max_faces])
	_polygons_timer.start()


## The Format dropdown is the Model Format setting. glTF shows only models
## with glTF, so search again.
func _on_model_format_changed() -> void:
	format_option.select(GalleryApi.option_index(plugin.MODEL_FORMATS, plugin.model_format))
	if _started:
		request_search()


## Results depend on the account (canDownload), so search again.
func _on_account_changed() -> void:
	if _started:
		request_search(true)


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


## Later downloads from the results use the asset's new files.
func _on_asset_refreshed(asset: Dictionary) -> void:
	var base_id := GalleryApi.base_id(asset)
	for i in results.size():
		if results[i] is Dictionary and GalleryApi.base_id(results[i]) == base_id:
			results[i] = asset
	if items.has(base_id):
		items[base_id].setup(asset)


func _on_download_dir_changed() -> void:
	for base_id in items:
		items[base_id].set_downloaded(gallery.is_downloaded(items[base_id].asset))
	if gallery.details.visible:
		gallery.details.refresh_download(true)


## A finished download this gallery didn't start, e.g. Send to Godot.
func _on_web_download_finished(file_path: String) -> void:
	var folder := file_path.get_base_dir()
	for base_id in items:
		if ProjectAssets.asset_folder(plugin.absolute_download_path, items[base_id].asset) == folder:
			items[base_id].set_downloaded(true)
