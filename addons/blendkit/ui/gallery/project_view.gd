@tool
extends VBoxContainer
## The assets downloaded to the project, shown by the gallery's project
## toggle: the downloads in progress, then the asset folders, see
## ProjectAssets. Folders the index doesn't know are looked up on Blendkit
## for their name and thumbnail.

const GalleryApi = preload("res://addons/blendkit/ui/gallery/gallery_api.gd")
const ClientTasks = preload("res://addons/blendkit/ui/gallery/client_tasks.gd")
const ProjectAssets = preload("res://addons/blendkit/ui/gallery/project_assets.gd")
const gallery_item_scene = preload("res://addons/blendkit/ui/gallery/gallery_item.tscn")

const WEB_DOWNLOAD_NAME := "Send to Godot"
const LOOKUP_TASK := "lookup"

@onready var message: Label = %ProjectMessage
@onready var grid: GridContainer = %ProjectGrid

var gallery: Node
var project: ProjectAssets
## Scanned asset folders with their tiles, see ProjectAssets.scan().
var entries: Array = []
## assetBaseId or task_id -> project tile of a download in progress.
var download_items: Dictionary = {}
## Asset id -> asset type of unknown folders to look up on Blendkit.
var _lookup_queue: Dictionary = {}
var _lookup_id := ""
var _lookup_type := ""
## Asset ids not found on Blendkit; not looked up again this session.
var _lookup_failed: Dictionary = {}
var _refresh_queued := false


## Called by the gallery once the plugin is known.
func setup(new_gallery: Node) -> void:
	gallery = new_gallery
	add_theme_constant_override("separation", int(20 * EditorInterface.get_editor_scale()))
	project = ProjectAssets.new()
	EditorInterface.get_resource_filesystem().filesystem_changed.connect(refresh_if_shown)
	gallery.downloads.download_changed.connect(_on_download_changed)
	gallery.downloads.download_finished.connect(_on_download_finished)
	gallery.downloads.web_download_finished.connect(func(_path): refresh_if_shown())
	gallery.downloads.web_asset_found.connect(_on_web_asset_found)


func has_pending_work() -> bool:
	return not _lookup_id.is_empty()


## Each refresh rescans the download directory, so the requests that come
## in one frame, e.g. a finished download and its import, share one.
func refresh_if_shown() -> void:
	if visible and not _refresh_queued:
		_refresh_queued = true
		_refresh_queued_if_shown.call_deferred()


func _refresh_queued_if_shown() -> void:
	if _refresh_queued and visible:
		refresh()
	_refresh_queued = false


## Rescan the download directory and update the tiles by entry id, so a
## lookup or thumbnail arriving only touches its own tile. Downloads in
## progress come first.
func refresh() -> void:
	_refresh_queued = false
	var new_entries := _download_entries()
	new_entries.append_array(project.scan(gallery.plugin.absolute_download_path))
	var old := {}
	for entry in entries:
		old[entry.id] = entry
	var current := {}
	var added := false
	download_items.clear()
	for entry in new_entries:
		if current.has(entry.id):
			continue
		var previous: Dictionary = old.get(entry.id, {})
		var item = previous.get("item")
		if item == null:
			added = true
			item = gallery_item_scene.instantiate()
			grid.add_child(item)
			item.selected.connect(_on_item_selected.bind(entry.id))
		if previous.is_empty() or previous.asset != entry.asset:
			item.setup(entry.asset)
		if previous.is_empty() or previous.thumbnail != entry.thumbnail:
			var texture := GalleryApi.load_texture(entry.thumbnail)
			if texture:
				item.set_thumbnail(texture)
			else:
				item.set_thumbnail_failed()
		if entry.has("download"):
			item.set_download(entry.download)
			download_items[entry.id] = item
		elif previous.has("download"):
			item.set_download({})
		grid.move_child(item, current.size())
		entry.item = item
		current[entry.id] = entry
	for id in old:
		if not current.has(id):
			grid.remove_child(old[id].item)
			old[id].item.queue_free()
	entries = current.values()
	if added:
		gallery.update_columns()
	filter()
	for entry in entries:
		if not entry.has("download") and not entry.known:
			_queue_lookup(entry.id, entry.asset.assetType)
	next_lookup()


## Project entries for the downloads in progress, like ProjectAssets.scan()
## with the download and its staging folder.
func _download_entries() -> Array:
	var result: Array = []
	var downloads = gallery.downloads
	var staging := GalleryApi.staging_path(gallery.plugin.absolute_download_path)
	for base_id in downloads.gallery_downloads:
		var dl: Dictionary = downloads.gallery_downloads[base_id]
		if dl.status in GalleryApi.ACTIVE_DOWNLOAD:
			result.append({"id": base_id, "file_path": "", "time": -1, "asset": dl.asset, "known": true,
				"thumbnail": gallery.thumb_cache.get(base_id, {}).get("small", ""), "download": dl,
				"folder": GalleryApi.asset_download_dir(staging, dl.asset)})
	for task_id in downloads.web_downloads:
		var web: Dictionary = downloads.web_downloads[task_id]
		var known: bool = not web.id.is_empty() and project.has(web.id)
		result.append({"id": task_id, "file_path": "", "time": -1, "asset": _web_download_asset(web),
			"known": known, "thumbnail": project.thumbnail(web.id) if known else "", "download": web,
			"folder": web.folder})
	return result


func _web_download_asset(web: Dictionary) -> Dictionary:
	if web.id.is_empty():
		return {"name": WEB_DOWNLOAD_NAME}
	if project.has(web.id):
		return project.get_asset(web.id)
	var file := ProjectAssets.main_file(web.folder)
	return {"id": web.id, "name": ProjectAssets.placeholder_name(file if file else web.folder),
		"assetType": web.asset_type}


func filter() -> void:
	var query: String = gallery.search_edit.text
	var shown := 0
	for entry in entries:
		entry.item.visible = ProjectAssets.matches(entry, query)
		if entry.item.visible:
			shown += 1
	message.visible = shown == 0
	grid.visible = shown > 0
	# The message and Browse Blendkit sit in the middle, otherwise the button
	# follows the tiles.
	alignment = BoxContainer.ALIGNMENT_CENTER if shown == 0 else BoxContainer.ALIGNMENT_BEGIN
	if entries.is_empty():
		message.text = "No assets downloaded yet to %s" % gallery.plugin.download_dir
	elif shown == 0:
		message.text = "No downloaded assets match \"%s\"." % query.strip_edges()


func add_thumbnail(base_id: String, path: String) -> void:
	if project.add_thumbnail(base_id, path):
		refresh_if_shown()


func _on_item_selected(_asset: Dictionary, id: String) -> void:
	for entry in entries:
		if entry.id == id:
			_open_details(entry)
			return


func _open_details(entry: Dictionary) -> void:
	if entry.has("download"):
		# Send to Godot downloads have no details until they finish.
		if entry.download.has("asset"):
			gallery.open_details(entry.asset)
		return
	var thumbs: Dictionary = gallery.thumb_cache.get(str(entry.asset.get("assetBaseId", "")), {}).duplicate()
	if entry.thumbnail and not thumbs.has("small"):
		thumbs.small = entry.thumbnail
	gallery.details.show_asset(entry.asset, thumbs, entry.file_path)


# MARK: downloads

## A download tile comes or goes when the download starts or ends, otherwise
## only its state changes.
func _on_download_changed(id: String) -> void:
	var dl: Dictionary = gallery.downloads.gallery_downloads.get(id, gallery.downloads.web_downloads.get(id, {}))
	if download_items.has(id) != (dl.get("status", "") in GalleryApi.ACTIVE_DOWNLOAD):
		refresh_if_shown()
	elif download_items.has(id):
		download_items[id].set_download(dl)


func _on_download_finished(base_id: String) -> void:
	project.store(gallery.downloads.get_download(base_id).asset, gallery.thumb_cache.get(base_id, {}).get("small", ""))
	refresh_if_shown()


## Look up the guessed asset for its name and thumbnail.
func _on_web_asset_found(task_id: String) -> void:
	var web: Dictionary = gallery.downloads.web_downloads[task_id]
	_queue_lookup(web.id, web.asset_type)
	next_lookup()
	refresh_if_shown()


# MARK: lookups

func _queue_lookup(id: String, asset_type: String) -> void:
	if not project.has(id) and not _lookup_failed.has(id) and id != _lookup_id:
		_lookup_queue[id] = asset_type


## Look up the next unknown asset folder on Blendkit, one at a time. The
## search task also downloads the thumbnail, see add_thumbnail().
func next_lookup() -> void:
	if not _lookup_id.is_empty() or _lookup_queue.is_empty() or not gallery.is_client_connected():
		return
	var id: String = _lookup_queue.keys()[0]
	var asset_type: String = _lookup_queue[id]
	_lookup_queue.erase(id)
	if project.has(id):
		next_lookup()
		return
	_lookup_id = id
	_lookup_type = asset_type
	var plugin: EditorPlugin = gallery.plugin
	var url := GalleryApi.build_lookup_url(plugin.SERVER, id, plugin.get_addon_version())
	var tempdir := GalleryApi.search_temp_dir(plugin.client_data_dir, asset_type)
	var post := func() -> Array:
		return await GalleryApi.search(self, plugin, url, asset_type, tempdir, 1)
	var response: Array = await gallery.tasks.start(LOOKUP_TASK, post, _finish_lookup)
	if response.is_empty():
		return # reset by a disconnect meanwhile
	if response[0].is_empty():
		plugin.bk_log(plugin.LogLevel.DEBUG, "Asset lookup failed: %s" % response[1])
		_finish_lookup({})


func _finish_lookup(task: Dictionary) -> void:
	if not task.is_empty() and not task.get("status") in ClientTasks.FINAL:
		return
	var id := _lookup_id
	_lookup_id = ""
	var result = task.get("result")
	var results = result.get("results") if result is Dictionary else null
	if task.get("status") == "finished" and results is Array and not results.is_empty() \
			and results[0] is Dictionary and str(results[0].get("id", "")) == id:
		var asset: Dictionary = results[0]
		project.store(asset, gallery.thumb_cache.get(str(asset.get("assetBaseId", "")), {}).get("small", ""))
		refresh_if_shown()
	else:
		gallery.plugin.bk_log(gallery.plugin.LogLevel.VERBOSE, "Asset %s not found on Blendkit" % id)
		_lookup_failed[id] = true
	next_lookup()


## A lookup in flight goes back into the queue.
func on_disconnected() -> void:
	if not _lookup_id.is_empty():
		_lookup_queue[_lookup_id] = _lookup_type
	_lookup_id = ""
