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

const GalleryApi = preload("res://addons/blendkit/ui/gallery/gallery_api.gd")
const ClientTasks = preload("res://addons/blendkit/ui/gallery/client_tasks.gd")
const ProjectAssets = preload("res://addons/blendkit/ui/gallery/project_assets.gd")
const FileReveal = preload("res://addons/blendkit/ui/file_reveal.gd")
const Conversions = preload("res://addons/blendkit/conversions.gd")
const FileOps = preload("res://addons/blendkit/file_ops.gd")

## How long before a Send to Godot task first shows its asset folder may have
## changed, and how long after to keep looking for it, in seconds.
const WEB_FOLDER_SLACK := 5
const WEB_FOLDER_SEARCH := 30
## The server's error for a file that no longer exists: the asset's files
## were regenerated since the search that listed them.
const STALE_FILE_ERROR := "No AssetFile matches"
const STALE_FILE_MESSAGE := "The asset's files changed on Blendkit. Search again to download it."
## A conversion still running after this long moves the file as it is.
const CONVERSION_TIMEOUT_MS := 5 * 60 * 1000

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
## The project's asset index, set by the project view.
var index: ProjectAssets
## Whether leftover staging folders were cleared since connecting.
var _staging_cleared := false
## Conversions waiting for their task's final report, key -> Conversion, see
## _convert().
var _conversions: Dictionary = {}
## The Client requests, replaced in the tests: post_download(asset,
## file_type), post_lookup(asset) and post_conversion(plan) return
## [task_id, error].
var post_download: Callable
var post_lookup: Callable
var post_conversion: Callable


func _init(parent: Node, plugin: EditorPlugin, tasks: ClientTasks) -> void:
	_parent = parent
	_plugin = plugin
	_tasks = tasks
	post_download = _post_download
	post_lookup = _post_lookup
	post_conversion = _post_conversion


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
			var staged := GalleryApi.task_file_path(task)
			var plan := Conversions.plan(staged)
			var converted := true
			if not plan.is_empty():
				# Not reported anymore, see drop_vanished().
				dl.reported = false
				dl.status = "converting"
				dl.progress = 100
				dl.message = Conversions.MESSAGE
				download_changed.emit(base_id)
				var result: Array = await _convert(staged, "convert:" + base_id, plan)
				staged = result[0]
				converted = result[1]
			dl.file_path = ProjectAssets.finish_download(staged, _plugin.uuid_names, base_id, converted)
			if dl.file_path.is_empty():
				_end(base_id, "error", "Could not move the download into %s" % _plugin.download_dir)
				return
			_log_finished(dl.file_path, converted)
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
			_log_ended(status, message)
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
	_log_ended(status, message)
	download_changed.emit(base_id)


## Log a download that ended without a file, once: a retried one goes on.
func _log_ended(status: String, message: String) -> void:
	if status == "error":
		_plugin.log_warning("Download failed: %s" % message)
	elif status == "cancelled":
		_plugin.log_info("Download cancelled")


func _post_download(asset: Dictionary, file_type: String) -> Array:
	if not _plugin.connection.is_client_connected():
		return ["", "Blendkit Client is not connected"]
	GalleryApi.ensure_staging(_plugin.absolute_download_path)
	var staging := GalleryApi.staging_path(_plugin.absolute_download_path)
	return await GalleryApi.download(_parent, _plugin, asset, file_type, staging)


## Search for the asset by its id, like the project view's lookups.
func _post_lookup(asset: Dictionary) -> Array:
	return await GalleryApi.lookup(_parent, _plugin, str(asset.get("id", "")), str(asset.get("assetType", "")))


## Log where a finished download went, see ProjectAssets.finish_download().
func _log_finished(path: String, converted: bool) -> void:
	var local := ProjectSettings.localize_path(path)
	# What moved unconverted would still need converting, unlike a kept file.
	if not converted and Conversions.plan(path).is_empty():
		_plugin.log_warning("Kept the existing %s, the new download couldn't be converted for Godot" % local)
	else:
		_plugin.log_info("Downloaded %s" % local)


## Let the editor import a finished download in the project, also when it
## replaced a file in place. Looking for changed files is much quicker than
## a full rescan.
static func _scan_download(file_path: String) -> void:
	if ProjectSettings.localize_path(file_path).begins_with("res://"):
		FileReveal.rescan(file_path)


# MARK: conversions

## Make a finished download in staging of use in Godot before it moves into
## the project, as [param plan] from Conversions.plan() says. Returns
## [file to move, converted]: the converted file, or failing, [param staged]
## as it is. The reports of its task go to [param key].
func _convert(staged: String, key: String, plan: Dictionary) -> Array:
	var output: String = plan.params.output_path
	var replaces: bool = plan.file == staged
	# The Client would take one left by an interrupted run as the result.
	DirAccess.remove_absolute(output)
	for dir in plan.dirs:
		FileOps.remove_dir(dir)
	var conversion := Conversion.new()
	_conversions[key] = conversion
	var on_task := func(task: Dictionary) -> void:
		if task.get("status") in ClientTasks.FINAL:
			conversion.end(task)
	var response: Array = await _tasks.start(key, post_conversion.bind(plan), on_task)
	var error := ""
	if response.is_empty() or not _conversions.has(key):
		error = "Blendkit Client disconnected"
	elif response[0].is_empty():
		error = response[1]
	else:
		if not conversion.done:
			_parent.get_tree().create_timer(CONVERSION_TIMEOUT_MS / 1000.0).timeout.connect(conversion.end)
			await conversion.ended
		var task := conversion.task
		if task.is_empty():
			_tasks.forget(key)
			error = "Blendkit Client disconnected" if not _conversions.has(key) else "Blender took too long"
		elif task.status != "finished":
			error = str(task.get("message", task.status))
			_plugin.log_debug("Blender output:\n%s" % task.get("message_detailed", ""))
		elif replaces and not FileOps.replace_file(output, staged):
			error = "could not replace it with the converted file"
	_conversions.erase(key)
	var file := staged.get_file()
	if error.is_empty():
		_plugin.log_verbose("Converted %s for Godot" % file)
		if not replaces:
			# what's left of no use in Godot
			DirAccess.remove_absolute(staged)
		return [plan.file, true]
	DirAccess.remove_absolute(output)
	for dir in plan.dirs:
		FileOps.remove_dir(dir)
	_plugin.log_warning("Could not convert %s for Godot, which may not import it: %s" % [file, error])
	return [staged, false]


## Run the conversion with Blender, see Conversions.blender_path().
func _post_conversion(plan: Dictionary) -> Array:
	if not _plugin.connection.is_client_connected():
		return ["", "Blendkit Client is not connected"]
	var blender: String = await Conversions.blender_path()
	var response := await GalleryApi.run_blender_script(_parent, _plugin, blender, plan.script,
		plan.params, plan.params.output_path, Conversions.MESSAGE)
	if response[0].is_empty() and blender.is_empty():
		Conversions.forget_detected()
		return ["", "Blender not found. Set it up in Blendkit > Settings > Blender Import."]
	return response


# MARK: Client connection

## The Client cancels the app's tasks when it unsubscribes. Conversions
## stop waiting and their downloads move into the project unconverted.
func on_disconnected() -> void:
	for conversion in _conversions.values():
		# Once the disconnect is handled, like a report would come.
		conversion.end.call_deferred()
	_conversions.clear()
	for base_id in gallery_downloads:
		var status: String = gallery_downloads[base_id].status
		if status in GalleryApi.ACTIVE_DOWNLOAD and status != "converting":
			_end(base_id, "error", "Blendkit Client disconnected")
	for task_id in web_downloads.keys():
		_drop_web_download(task_id)
	_staging_cleared = false


## Unfinished tasks are reported on every poll, so a download missing from a
## report is gone, e.g. cancelled in the Client. [param reported] holds the
## report's task ids.
func drop_vanished(reported: Dictionary) -> void:
	for task_id in web_downloads.keys():
		if not reported.has(task_id) and web_downloads[task_id].status != "converting":
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
	if status == "finished":
		_finish_web_download(task)
		return
	if not status in GalleryApi.ACTIVE_DOWNLOAD:
		# A gallery download logged its end already, e.g. cancelled.
		if not _is_gallery_task(task_id):
			_log_ended(status, str(task.get("message", "")))
		_drop_web_download(task_id)
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


## The asset's base id is known once its lookup finished, see index. A
## download shown in progress shows converting meanwhile, if it does.
func _finish_web_download(task: Dictionary) -> void:
	var task_id: String = task.get("task_id", "")
	var staged := GalleryApi.task_file_path(task)
	var plan := Conversions.plan(staged)
	var converted := true
	if not plan.is_empty():
		var web: Dictionary = web_downloads.get(task_id, {})
		if web:
			web.status = "converting"
			web.progress = 100
			web.message = Conversions.MESSAGE
			download_changed.emit(task_id)
		var result: Array = await _convert(staged, "convert:" + task_id, plan)
		staged = result[0]
		converted = result[1]
	_drop_web_download(task_id)
	var id := ProjectAssets.folder_asset_id(staged.get_base_dir().get_file())
	var base_id := GalleryApi.base_id(index.get_asset(id)) if index and id else ""
	var path := ProjectAssets.finish_download(staged, _plugin.uuid_names, base_id, converted)
	if path.is_empty():
		_plugin.log_warning("Could not move %s into %s" % [staged, _plugin.download_dir])
		return
	_log_finished(path, converted)
	_scan_download(path)
	web_download_finished.emit(path)


func _is_gallery_task(task_id: String) -> bool:
	for base_id in gallery_downloads:
		if gallery_downloads[base_id].task_id == task_id:
			return true
	return false


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


## A conversion waiting for its task's final report, ended by it, a
## disconnect or the timeout, whichever comes first.
class Conversion:
	signal ended
	var done := false
	## The final report, {} without one.
	var task: Dictionary = {}

	func end(final_task: Dictionary = {}) -> void:
		if done:
			return
		done = true
		task = final_task
		ended.emit()
