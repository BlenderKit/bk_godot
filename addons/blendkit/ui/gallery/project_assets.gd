@tool
extends RefCounted
## Assets downloaded to the project: asset folders found in the download
## directory, described by an index kept in the project data directory
## (.godot/blendkit), so nothing is added to the project itself.
##
## The index is a cache: entries come from gallery downloads and from looking
## up folders by the asset id in their name, and it can be deleted at any time.

const GalleryApi = preload("res://addons/blendkit/ui/gallery/gallery_api.gd")

const INDEX_FILE := "blendkit_assets.cfg"
const INDEX_VERSION := 1
const THUMBNAILS_DIR := "thumbnails"
## Section with the index format version, the others are asset ids.
const META_SECTION := "index"
## Asset fields kept in the index; account-specific ones like canDownload
## are left out.
const KEPT_FIELDS := ["id", "assetBaseId", "name", "displayName", "assetType", "author",
	"license", "tags", "isFree", "score", "ratingsAverage", "ratingsCount", "ratingsMedian",
	"filesSize", "created", "dictParameters", "description"]

static var _asset_id_regex := RegEx.create_from_string("_([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$")
## A file the Client downloaded, named <slug>_<variant>_<file id>.<ext>, see
## its ServerToLocalFilename(): the variant is gltf_godot, gltf or a
## resolution like 2K, and the original .blend has none. Files Godot writes
## next to them, like textures extracted from a .glb, have more after the id.
static var _download_file_regex := RegEx.create_from_string("_(?:(gltf_godot|gltf|zip_file|[0-9_]+K)_)?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\.[^.]+$")

## Absolute path of the index directory.
var dir: String
var index := ConfigFile.new()
## Whether the index changed since it was saved, see save().
var unsaved := false
## assetBaseId -> ids of indexed assets without a thumbnail, so a thumbnail
## from browsing doesn't search the whole index. Built on first use.
var _no_thumbnail = null


func _init(index_dir: String = "") -> void:
	dir = index_dir if index_dir else default_dir()
	var path := dir.path_join(INDEX_FILE)
	if FileAccess.file_exists(path) and index.load(path) != OK:
		push_warning("Blendkit: Ignoring unreadable asset index %s" % path)
		index = ConfigFile.new()
	if index.get_value(META_SECTION, "version", INDEX_VERSION) != INDEX_VERSION:
		index = ConfigFile.new()


## <project>/.godot/blendkit, or godot/blendkit when the project data
## directory isn't hidden.
static func default_dir() -> String:
	var hidden: bool = ProjectSettings.get_setting("application/config/use_hidden_project_data_directory", true)
	return ProjectSettings.globalize_path("res://%s/blendkit" % (".godot" if hidden else "godot"))


# MARK: index

func has(id: String) -> bool:
	return index.has_section(id)


func get_asset(id: String) -> Dictionary:
	return index.get_value(id, "asset", {}) if has(id) else {}


## Add or update the asset, copying its thumbnail into the index directory.
## Saved by save().
func store(asset: Dictionary, thumbnail_path: String = "") -> void:
	var id := str(asset.get("id", ""))
	if id.is_empty():
		return
	index.set_value(id, "asset", trim_asset(asset))
	if thumbnail_path.is_empty() or not _copy_thumbnail(id, thumbnail_path):
		_note_no_thumbnail(id)
	unsaved = true


## Set the thumbnail of indexed assets with this base id that have none.
## Returns the ids of those that changed. Saved by save().
func add_thumbnail(base_id: String, thumbnail_path: String) -> PackedStringArray:
	if _no_thumbnail == null:
		_no_thumbnail = {}
		for id in index.get_sections():
			if id != META_SECTION:
				_note_no_thumbnail(id)
	var changed := PackedStringArray()
	for id in _no_thumbnail.get(base_id, []).duplicate():
		if _copy_thumbnail(id, thumbnail_path):
			changed.append(id)
	if not changed.is_empty():
		unsaved = true
	return changed


## Keep track of the asset if it has no thumbnail, see _no_thumbnail.
func _note_no_thumbnail(id: String) -> void:
	if _no_thumbnail == null or not thumbnail(id).is_empty():
		return
	var base_id := str(get_asset(id).get("assetBaseId", ""))
	if base_id.is_empty():
		return
	var ids: Array = _no_thumbnail.get_or_add(base_id, [])
	if not id in ids:
		ids.append(id)


## Absolute path of the asset's thumbnail, or "".
func thumbnail(id: String) -> String:
	var file := str(index.get_value(id, "thumbnail", ""))
	return dir.path_join(THUMBNAILS_DIR).path_join(file) if file else ""


## Write the index if it changed.
func save() -> void:
	if not unsaved:
		return
	unsaved = false
	DirAccess.make_dir_recursive_absolute(dir)
	index.set_value(META_SECTION, "version", INDEX_VERSION)
	var err := index.save(dir.path_join(INDEX_FILE))
	if err != OK:
		push_warning("Blendkit: Could not save the asset index (error %d)" % err)


func _copy_thumbnail(id: String, source: String) -> bool:
	if not FileAccess.file_exists(source):
		return false
	var thumbs := dir.path_join(THUMBNAILS_DIR)
	DirAccess.make_dir_recursive_absolute(thumbs)
	var file := id + "." + source.get_extension()
	if DirAccess.copy_absolute(source, thumbs.path_join(file)) != OK:
		return false
	index.set_value(id, "thumbnail", file)
	if _no_thumbnail != null:
		var base_id := str(get_asset(id).get("assetBaseId", ""))
		var ids: Array = _no_thumbnail.get(base_id, [])
		ids.erase(id)
		if ids.is_empty():
			_no_thumbnail.erase(base_id)
	return true


static func trim_asset(asset: Dictionary) -> Dictionary:
	var trimmed := {}
	for key in KEPT_FIELDS:
		if asset.has(key):
			trimmed[key] = asset[key]
	return trimmed


# MARK: scanning

## Asset folders with downloaded files in the download directory, newest
## first: [{id, folder, files, time, asset, known, thumbnail}], files as in
## downloaded_files(). Folders not in the index get a placeholder asset named
## after their newest file.
func scan(abs_download_path: String) -> Array:
	var entries: Array = []
	for asset_type in GalleryApi.ASSET_TYPES:
		var type_dir := GalleryApi.type_download_dir(abs_download_path, asset_type)
		if not DirAccess.dir_exists_absolute(type_dir):
			continue
		for folder in DirAccess.get_directories_at(type_dir):
			var id := folder_asset_id(folder)
			var path := type_dir.path_join(folder)
			var files := downloaded_files(path) if id else {}
			if files.is_empty():
				continue
			var file := newest_file(files.values())
			var known := has(id)
			var asset: Dictionary = get_asset(id) if known else \
				{"id": id, "name": placeholder_name(file), "assetType": asset_type}
			entries.append({
				"id": id,
				"folder": path,
				"files": files,
				"time": FileAccess.get_modified_time(file),
				"asset": asset,
				"known": known,
				"thumbnail": thumbnail(id),
			})
	entries.sort_custom(func(a, b): return a.time > b.time)
	return entries


## The asset folder in the [param staging] folder that the Client most
## likely just started downloading into: the one changed most recently, at or
## after [param since] (Unix time), leaving out [param taken] folders. Send
## to Godot tasks don't say which asset they download, but the Client creates
## its folder and file right before. Returns {folder, id, asset_type}, or {}
## if none changed.
static func recent_download_folder(staging: String, since: int, taken: Dictionary = {}) -> Dictionary:
	var found := {}
	var found_time := since - 1
	for asset_type in GalleryApi.ASSET_TYPES:
		var type_dir := GalleryApi.type_download_dir(staging, asset_type)
		if not DirAccess.dir_exists_absolute(type_dir):
			continue
		for folder in DirAccess.get_directories_at(type_dir):
			var path := type_dir.path_join(folder)
			var id := folder_asset_id(folder)
			if id.is_empty() or taken.has(path):
				continue
			var time := FileAccess.get_modified_time(path)
			var file := main_file(path)
			if not file.is_empty():
				time = maxi(time, FileAccess.get_modified_time(file))
			if time > found_time:
				found = {"folder": path, "id": id, "asset_type": asset_type}
				found_time = time
	return found


## The asset id of a folder named <slug>_<id> by the Client, or "".
static func folder_asset_id(folder: String) -> String:
	var m := _asset_id_regex.search(folder)
	return m.get_string(1) if m else ""


## The most recently written file the Client downloaded into the folder,
## or "".
static func main_file(folder: String) -> String:
	return newest_file(downloaded_files(folder).values())


static func newest_file(paths: Array) -> String:
	var newest := ""
	var newest_time := -1
	for path in paths:
		var time := FileAccess.get_modified_time(path)
		if time > newest_time:
			newest = path
			newest_time = time
	return newest


## The fileType of a file the Client downloaded, e.g. "resolution_2K" for
## "chair_2K_<file id>.blend", or "" for other files.
static func download_file_type(file_path: String) -> String:
	var m := _download_file_regex.search(file_path.get_file())
	if not m:
		return ""
	var variant := m.get_string(1)
	if variant.is_empty():
		return "blend"
	if variant.ends_with("K"):
		return "resolution_" + variant
	return variant


## The files the Client downloaded into the folder: fileType -> path, the
## newest of each type.
static func downloaded_files(folder: String) -> Dictionary:
	var files := {}
	var times := {}
	if folder.is_empty() or not DirAccess.dir_exists_absolute(folder):
		return files
	for file in DirAccess.get_files_at(folder):
		var file_type := download_file_type(file)
		if file_type.is_empty():
			continue
		var path := folder.path_join(file)
		var time := FileAccess.get_modified_time(path)
		if time >= times.get(file_type, -1):
			files[file_type] = path
			times[file_type] = time
	return files


## Readable name from a downloaded file named <slug>_<server name> by the
## Client, e.g. "wooden-chair_gltf_godot.glb" -> "Wooden Chair".
static func placeholder_name(file_path: String) -> String:
	return file_path.get_file().get_basename().get_slice("_", 0).replace("-", " ").capitalize()


## Whether every word of the query appears in the asset's name, author,
## tags, type or file names.
static func matches(entry: Dictionary, query: String) -> bool:
	var asset: Dictionary = entry.asset
	var tags = asset.get("tags", [])
	var haystack := " ".join(PackedStringArray([
		asset.get("displayName", ""), asset.get("name", ""), GalleryApi.author_name(asset),
		" ".join(PackedStringArray(tags if tags is Array else [])),
		GalleryApi.ASSET_TYPE_LABELS.get(asset.get("assetType", ""), ""),
		" ".join(PackedStringArray(entry.get("files", {}).values().map(func(p): return p.get_file()))),
	])).to_lower()
	for word in query.to_lower().split(" ", false):
		if not haystack.contains(word):
			return false
	return true
