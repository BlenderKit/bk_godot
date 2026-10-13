@tool
extends RefCounted
## Downloads started from the gallery and Send to Godot downloads from
## blendkit.com, with their progress from the Client's task reports. The
## search tiles, project view and details listen to its signals.

## A download's state changed, [param id] is the assetBaseId of a gallery
## download or the task_id of a Send to Godot download.
signal download_changed(id: String)
## A gallery download moved into the project.
signal download_finished(base_id: String)
## A Send to Godot download moved into the project.
signal web_download_finished(file_path: String)
## The asset folder of a Send to Godot download was guessed.
signal web_asset_found(task_id: String)
## A gallery download looked up its asset again, see _refresh().
signal asset_refreshed(asset: Dictionary)

const ClientBinary = preload("res://addons/blendkit/client_binary.gd")
const GalleryApi = preload("res://addons/blendkit/ui/gallery/gallery_api.gd")
const ClientTasks = preload("res://addons/blendkit/ui/gallery/client_tasks.gd")
const ProjectAssets = preload("res://addons/blendkit/ui/gallery/project_assets.gd")

## How long before a Send to Godot task first shows its asset folder may have
## changed, and how long after to keep looking for it, in seconds.
const WEB_FOLDER_SLACK := 5
const WEB_FOLDER_SEARCH := 30
## The server's error for a file that no longer exists: the asset's files
## were regenerated since the search that listed them.
const STALE_FILE_ERROR := "No AssetFile matches"
const STALE_FILE_MESSAGE := "The asset's files changed on Blendkit. Search again to download it."

## assetBaseId -> {task_id, status, progress, message, file_type, file_path,
## asset, reported, retried}
var gallery_downloads: Dictionary = {}
## Send to Godot downloads from blendkit.com, task_id -> {task_id, status,
## progress, message, since, folder, id, asset_type}. Their tasks don't say
## which asset they download, so the staging folder is guessed, see
## ProjectAssets.recent_download_folder().
var web_downloads: Dictionary = {}

## The requests run under this node, see GalleryApi.
var _parent: Node
var _plugin: EditorPlugin
var _tasks: ClientTasks
## Whether leftover staging folders were cleared since connecting.
var _staging_cleared := false
## The Client requests, replaced in the tests: post_download(asset,
## file_type) and post_lookup(asset) return [task_id, error].
var post_download: Callable
var post_lookup: Callable


func _init(parent: Node, plugin: EditorPlugin, tasks: ClientTasks) -> void:
	_parent = parent
	_plugin = plugin
	_tasks = tasks
	post_download = _post_download
	post_lookup = _post_lookup


func get_download(base_id: String) -> Dictionary:
	return gallery_downloads.get(base_id, {})


## Gallery and Send to Godot downloads in progress.
func active_count() -> int:
	var count := web_downloads.size()
	for base_id in gallery_downloads:
		if gallery_downloads[base_id].status in GalleryApi.ACTIVE_DOWNLOAD:
			count += 1
	return count


func has_pending_work() -> bool:
	return active_count() > 0


## Staging folders of the downloads in progress.
func active_folders() -> Dictionary:
	var folders := {}
	var staging := GalleryApi.staging_path(_plugin.absolute_download_path)
	for base_id in gallery_downloads:
		var dl: Dictionary = gallery_downloads[base_id]
		if dl.status in GalleryApi.ACTIVE_DOWNLOAD:
			folders[GalleryApi.asset_download_dir(staging, dl.asset)] = true
	for task_id in web_downloads:
		if not web_downloads[task_id].folder.is_empty():
			folders[web_downloads[task_id].folder] = true
	return folders


# MARK: gallery downloads

func start(asset: Dictionary, file_type: String) -> void:
	var base_id := GalleryApi.base_id(asset)
	if get_download(base_id).get("status", "") in GalleryApi.ACTIVE_DOWNLOAD:
		return
	gallery_downloads[base_id] = {"task_id": "", "status": "", "progress": 0, "message": "",
		"file_type": file_type, "file_path": "", "asset": asset, "retried": false}
	_post(base_id)


## Start the Client's task for the download, also again after _refresh().
func _post(base_id: String) -> void:
	var dl: Dictionary = gallery_downloads[base_id]
	dl.task_id = ""
	dl.status = "posting"
	dl.progress = 0
	dl.message = "Starting download"
	dl.reported = false
	download_changed.emit(base_id)
	var post := post_download.bind(dl.asset, dl.file_type)
	var response: Array = await _tasks.start("download:" + base_id, post, _apply_task.bind(base_id))
	if response.is_empty():
		return # reset by a disconnect meanwhile
	if response[0].is_empty():
		_end(base_id, "error", response[1])
	elif dl.status == "posting": # unless an early report was applied already
		dl.task_id = response[0]
		dl.status = "created"
		download_changed.emit(base_id)


func _apply_task(task: Dictionary, base_id: String) -> void:
	var dl: Dictionary = gallery_downloads[base_id]
	if not dl.status in GalleryApi.ACTIVE_DOWNLOAD:
		return
	var status: String = task.get("status", "")
	dl.task_id = str(task.get("task_id", ""))
	dl.reported = true
	match status:
		"created", "progress":
			dl.status = status
			dl.progress = int(task.get("progress", 0))
			dl.message = str(task.get("message", ""))
		"finished":
			dl.file_path = GalleryApi.finish_download(GalleryApi.task_file_path(task))
			if dl.file_path.is_empty():
				_end(base_id, "error", "Could not move the download into %s" % _plugin.download_dir)
				return
			dl.status = "finished"
			dl.progress = 100
			dl.message = ""
			download_finished.emit(base_id)
			_scan_download(dl.file_path)
		"error", "cancelled":
			var message := str(task.get("message", "")) if status == "error" else ""
			if message.contains(STALE_FILE_ERROR):
				if not dl.retried:
					_refresh(base_id)
					return
				message = STALE_FILE_MESSAGE
			dl.status = status
			dl.message = message
	download_changed.emit(base_id)


## The asset's files changed on Blendkit since the search, so look the asset
## up for the new ones and download again, once. The download stays active
## meanwhile, without a task to cancel or to vanish from the reports.
func _refresh(base_id: String) -> void:
	var dl: Dictionary = gallery_downloads[base_id]
	dl.retried = true
	dl.task_id = ""
	dl.status = "refreshing"
	dl.reported = false
	dl.message = "Refreshing asset data"
	download_changed.emit(base_id)
	var post := post_lookup.bind(dl.asset)
	var response: Array = await _tasks.start("download:" + base_id, post, _finish_refresh.bind(base_id))
	if response.is_empty():
		return # reset by a disconnect meanwhile
	if response[0].is_empty():
		_plugin.log_debug("Asset lookup failed: %s" % response[1])
		_end(base_id, "error", STALE_FILE_MESSAGE)


func _finish_refresh(task: Dictionary, base_id: String) -> void:
	var dl: Dictionary = gallery_downloads[base_id]
	if not task.get("status") in ClientTasks.FINAL or dl.status != "refreshing":
		return
	var asset := GalleryApi.lookup_result(task, str(dl.asset.get("id", "")))
	if not dl.file_type in GalleryApi.file_types(asset):
		_end(base_id, "error", STALE_FILE_MESSAGE)
		return
	dl.asset = asset
	asset_refreshed.emit(asset)
	_post(base_id)


## The Client cancels asynchronously and answers once it got the request,
## so the download runs on if the request fails.
func cancel(task_id: String) -> void:
	var response := await GalleryApi.cancel_download(_parent, _plugin, task_id)
	for base_id in gallery_downloads:
		var dl: Dictionary = gallery_downloads[base_id]
		if dl.task_id != task_id or not dl.status in GalleryApi.ACTIVE_DOWNLOAD:
			continue
		if response.ok:
			# A cancelled task can disappear without a final report.
			_end(base_id, "cancelled")
		else:
			_plugin.log_warning("Could not cancel the download: %s" % response.error)
			dl.message = "Could not cancel: %s" % response.error
			download_changed.emit(base_id)


## End a gallery download that isn't reported anymore, and stop waiting for
## its reports.
func _end(base_id: String, status: String, message: String = "") -> void:
	var dl: Dictionary = gallery_downloads[base_id]
	dl.status = status
	dl.message = message
	_tasks.forget("download:" + base_id)
	download_changed.emit(base_id)


func _post_download(asset: Dictionary, file_type: String) -> Array:
	if not _plugin.connection.is_client_connected():
		return ["", "Blendkit Client is not connected"]
	GalleryApi.ensure_staging(_plugin.absolute_download_path)
	var staging := GalleryApi.staging_path(_plugin.absolute_download_path)
	return await GalleryApi.download(_parent, _plugin, asset, file_type, staging)


## Search for the asset by its id, like the project view's lookups.
func _post_lookup(asset: Dictionary) -> Array:
	var asset_type := str(asset.get("assetType", ""))
	var url := GalleryApi.build_lookup_url(_plugin.SERVER, str(asset.get("id", "")), _plugin.get_addon_version())
	var tempdir := GalleryApi.search_temp_dir(ClientBinary.get_client_data_dir(), asset_type)
	return await GalleryApi.search(_parent, _plugin, url, asset_type, tempdir, 1)


## Let the editor import a finished download in the project. Looking for
## changed files is much quicker than a full rescan.
static func _scan_download(file_path: String) -> void:
	if ProjectSettings.localize_path(file_path).begins_with("res://"):
		EditorInterface.get_resource_filesystem().scan_sources()


# MARK: Client connection

## The Client cancels the app's tasks when it unsubscribes.
func on_disconnected() -> void:
	for base_id in gallery_downloads:
		if gallery_downloads[base_id].status in GalleryApi.ACTIVE_DOWNLOAD:
			_end(base_id, "error", "Blendkit Client disconnected")
	for task_id in web_downloads.keys():
		_drop_web_download(task_id)
	_staging_cleared = false


## Unfinished tasks are reported on every poll, so a download missing from a
## report is gone, e.g. cancelled in the Client. [param reported] holds the
## report's task ids.
func drop_vanished(reported: Dictionary) -> void:
	for task_id in web_downloads.keys():
		if not reported.has(task_id):
			_drop_web_download(task_id)
	# Once the report shows which downloads still run, clear the rest.
	if not _staging_cleared:
		_staging_cleared = true
		var cleared := GalleryApi.clear_staging(_plugin.absolute_download_path, active_folders())
		if cleared > 0:
			_plugin.log_verbose("Deleted %d unfinished downloads" % cleared)
	for base_id in gallery_downloads:
		var dl: Dictionary = gallery_downloads[base_id]
		if dl.get("reported", false) and dl.status in GalleryApi.ACTIVE_DOWNLOAD and not reported.has(dl.task_id):
			_end(base_id, "cancelled")


# MARK: Send to Godot downloads

## An asset_download task the gallery didn't start: Send to Godot on
## blendkit.com.
func handle_web_task(task: Dictionary) -> void:
	var task_id: String = task.get("task_id", "")
	var status: String = task.get("status", "")
	if not status in GalleryApi.ACTIVE_DOWNLOAD:
		_drop_web_download(task_id)
		if status == "finished":
			_finish_web_download(task)
		return
	if not web_downloads.has(task_id):
		web_downloads[task_id] = {"task_id": task_id, "folder": "", "id": "", "asset_type": "",
			"since": int(Time.get_unix_time_from_system()) - WEB_FOLDER_SLACK}
		# The Client made the staging folder, but not its .gitignore.
		GalleryApi.ensure_staging(_plugin.absolute_download_path)
	var web: Dictionary = web_downloads[task_id]
	web.status = status
	web.progress = int(task.get("progress", 0))
	web.message = str(task.get("message", ""))
	if web.folder.is_empty() and Time.get_unix_time_from_system() < web.since + WEB_FOLDER_SLACK + WEB_FOLDER_SEARCH \
			and _find_web_download_folder(web):
		web_asset_found.emit(task_id)
	download_changed.emit(task_id)


func _finish_web_download(task: Dictionary) -> void:
	var path := GalleryApi.finish_download(GalleryApi.task_file_path(task))
	if path.is_empty():
		_plugin.log_warning("Could not move %s into %s" % [GalleryApi.task_file_path(task), _plugin.download_dir])
		return
	_scan_download(path)
	web_download_finished.emit(path)


func _drop_web_download(task_id: String) -> void:
	if web_downloads.erase(task_id):
		download_changed.emit(task_id)


## Guess the asset the Send to Godot task downloads from the folder that
## changed last. Returns whether a folder was found.
func _find_web_download_folder(web: Dictionary) -> bool:
	var staging := GalleryApi.staging_path(_plugin.absolute_download_path)
	var found := ProjectAssets.recent_download_folder(staging, web.since, active_folders())
	if found.is_empty():
		return false
	web.merge(found, true)
	return true
