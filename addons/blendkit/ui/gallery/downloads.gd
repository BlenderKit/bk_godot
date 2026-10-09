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

const GalleryApi = preload("res://addons/blendkit/ui/gallery/gallery_api.gd")
const ClientTasks = preload("res://addons/blendkit/ui/gallery/client_tasks.gd")
const ProjectAssets = preload("res://addons/blendkit/ui/gallery/project_assets.gd")

## How long before a Send to Godot task first shows its asset folder may have
## changed, and how long after to keep looking for it, in seconds.
const WEB_FOLDER_SLACK := 5
const WEB_FOLDER_SEARCH := 30

## assetBaseId -> {task_id, status, progress, message, file_type, file_path,
## asset, reported}
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


func _init(parent: Node, plugin: EditorPlugin, tasks: ClientTasks) -> void:
	_parent = parent
	_plugin = plugin
	_tasks = tasks


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
	var dl := {"task_id": "", "status": "posting", "progress": 0, "message": "Starting download",
		"file_type": file_type, "file_path": "", "asset": asset}
	gallery_downloads[base_id] = dl
	if not _plugin.is_client_connected():
		dl.status = "error"
		dl.message = "Blendkit Client is not connected"
		download_changed.emit(base_id)
		return
	download_changed.emit(base_id)
	GalleryApi.ensure_staging(_plugin.absolute_download_path)
	var staging := GalleryApi.staging_path(_plugin.absolute_download_path)
	var post := func() -> Array:
		return await GalleryApi.download(_parent, _plugin, asset, file_type, staging)
	var response: Array = await _tasks.start("download:" + base_id, post, _apply_task.bind(base_id))
	if response.is_empty():
		return # reset by a disconnect meanwhile
	if response[0].is_empty():
		dl.status = "error"
		dl.message = response[1]
		download_changed.emit(base_id)
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
				dl.status = "error"
				dl.message = "Could not move the download into %s" % _plugin.download_dir
				download_changed.emit(base_id)
				return
			dl.status = "finished"
			dl.progress = 100
			dl.message = ""
			download_finished.emit(base_id)
			_scan_download(dl.file_path)
		"error", "cancelled":
			dl.status = status
			dl.message = str(task.get("message", "")) if status == "error" else ""
	download_changed.emit(base_id)


func cancel(task_id: String) -> void:
	await GalleryApi.cancel_download(_parent, _plugin, task_id)
	# A cancelled task can disappear without a final report.
	for base_id in gallery_downloads:
		var dl: Dictionary = gallery_downloads[base_id]
		if dl.task_id == task_id and dl.status in GalleryApi.ACTIVE_DOWNLOAD:
			dl.status = "cancelled"
			dl.message = ""
			download_changed.emit(base_id)


## Let the editor import a finished download in the project. Looking for
## changed files is much quicker than a full rescan.
static func _scan_download(file_path: String) -> void:
	if ProjectSettings.localize_path(file_path).begins_with("res://"):
		EditorInterface.get_resource_filesystem().scan_sources()


# MARK: Client connection

## The Client cancels the app's tasks when it unsubscribes.
func on_disconnected() -> void:
	for base_id in gallery_downloads:
		var dl: Dictionary = gallery_downloads[base_id]
		if dl.status in GalleryApi.ACTIVE_DOWNLOAD:
			dl.status = "error"
			dl.message = "Blendkit Client disconnected"
			download_changed.emit(base_id)
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
			dl.status = "cancelled"
			dl.message = ""
			download_changed.emit(base_id)


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
		_plugin.update_poll_rate()
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
