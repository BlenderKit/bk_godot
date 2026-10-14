@tool
extends RefCounted
## Assets downloaded to the project: asset folders found in the download
## directory, described by an index kept in the project data directory
## (.godot/blendkit), so nothing is added to the project itself.
##
## The index is a cache: entries come from gallery downloads and from looking
## up folders by the asset id in their name, and it can be deleted at any time.

const GalleryApi = preload("res://addons/blendkit/ui/gallery/gallery_api.gd")
const FileOps = preload("res://addons/blendkit/file_ops.gd")
const Conversions = preload("res://addons/blendkit/conversions.gd")

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

## How much of the asset and file ids the downloaded folders and files are
## named with, see finish_download(): all of it like the Client, the first
## SHORT_ID_LENGTH characters, or none.
const UUID_NAMES_FULL := "full"
const UUID_NAMES_SHORT := "short"
const UUID_NAMES_STRIP := "strip"
const SHORT_ID_LENGTH := 8
## Name of the assets whose name has no letters or digits.
const NAMELESS_SLUG := "asset"
## Hidden file in each asset folder with the asset's ids and the files
## downloaded into it, as their names may not have the ids. Godot skips
## hidden files, version control keeps it.
const MANIFEST_FILE := ".blendkit"
const MANIFEST_SECTION := "asset"

static var _asset_id_regex := RegEx.create_from_string("_([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$")
## A file the Client downloaded, named <slug>_<variant>_<file id>.<ext>, see
## its ServerToLocalFilename(): the slug has no "_", the variant is
## gltf_godot, gltf or a resolution like 2K, and the original .blend has
## none. Files Godot writes next to them, like textures extracted from a
## .glb, have more after the id.
static var _download_file_regex := RegEx.create_from_string("^([^_]*)_(?:(gltf_godot|gltf|zip_file|[0-9_]+K)_)?([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\\.([^.]+)$")
## The uid in a text resource's header.
static var _uid_regex := RegEx.create_from_string(" uid=\"(uid://[^\"]+)\"")

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
			var path := type_dir.path_join(folder)
			var manifest := read_manifest(path)
			var id := folder_id(path, manifest)
			var times := {}
			var files := _downloaded_files(path, "", manifest, times) if id else {}
			if files.is_empty():
				continue
			var newest := ""
			for file_type in files:
				if newest.is_empty() or times[file_type] > times[newest]:
					newest = file_type
			var file: String = files[newest]
			var known := has(id)
			var asset: Dictionary = get_asset(id) if known else \
				{"id": id, "name": placeholder_name(file), "assetType": asset_type}
			entries.append({
				"id": id,
				"folder": path,
				"files": files,
				"time": times[newest],
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


## The asset id of the folder at [param path] from its manifest or its
## name, or "". Pass the folder's [param manifest] if read already.
static func folder_id(path: String, manifest: Variant = null) -> String:
	var id := str((read_manifest(path) if manifest == null else manifest).get("id", ""))
	return id if id else folder_asset_id(path.get_file())


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
	var variant := m.get_string(2)
	if variant.is_empty():
		return "blend"
	if variant.ends_with("K"):
		return "resolution_" + variant
	return variant


## The files the Client downloaded into the folder, by its manifest or their
## names: fileType -> path, the newest of each type. With [param version],
## only those of that version of the asset, see read_manifest(); files the
## manifest doesn't list are of the folder's version.
static func downloaded_files(folder: String, version: String = "") -> Dictionary:
	if folder.is_empty() or not DirAccess.dir_exists_absolute(folder):
		return {}
	return _downloaded_files(folder, version, read_manifest(folder), {})


## downloaded_files() with the folder's [param manifest], filling [param times]
## with the modification time of each type's file.
static func _downloaded_files(folder: String, version: String, manifest: Dictionary, times: Dictionary) -> Dictionary:
	var files := {}
	var listed: Dictionary = manifest.get("files", {})
	var versions: Dictionary = manifest.get("versions", {})
	var folder_version := str(manifest.get("id", "")) if manifest else folder_asset_id(folder.get_file())
	for file in DirAccess.get_files_at(folder):
		var file_type := str(listed.get(file, download_file_type(file)))
		if file_type.is_empty() or (version and versions.get(file, folder_version) != version):
			continue
		var path := folder.path_join(file)
		var time := FileAccess.get_modified_time(path)
		if time >= times.get(file_type, -1):
			files[file_type] = path
			times[file_type] = time
	return files


# MARK: folders

## Move a finished download from the staging folder into the download
## directory, replacing the file of its type there, whose .import and .uid
## stay so references keep working. An older file in another format, like a
## material .blend before it was converted, is deleted instead. Folders next
## to the download, like the textures of a converted material, move along,
## replacing files in the folders of the same name. If anything fails to
## move, what moved goes back and the replaced files are restored. A
## download that wasn't [param converted] as it should have been doesn't
## replace a file of its type Godot uses as it is, which stays instead. The
## folder and file are named as [param uuid_names] says, see
## destination_folder() and renamed_file(), and the folder's manifest lists
## the file. Returns the new or kept path; "" if there's no file to move or
## the move failed.
static func finish_download(path: String, uuid_names: String = UUID_NAMES_FULL, base_id: String = "", converted: bool = true) -> String:
	var staged_folder := path.get_base_dir()
	var client_folder := staged_folder.get_file()
	var folder := GalleryApi.unstaged_path(staged_folder)
	if folder == staged_folder:
		return path if FileAccess.file_exists(path) else "" # not staged
	var file_name := path.get_file()
	var file_type := download_file_type(file_name)
	var id := folder_asset_id(client_folder)
	if id:
		var m := _download_file_regex.search(file_name)
		var slug := m.get_string(1) if m else client_folder.get_slice("_", 0)
		folder = destination_folder(folder.get_base_dir(), client_folder, slug, id, base_id, uuid_names)
	var target := folder.path_join(renamed_file(file_name, uuid_names) if id else file_name)
	var older: String = downloaded_files(folder).get(file_type, "") if file_type else ""
	if not converted and older and Conversions.plan(older).is_empty():
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
			DirAccess.remove_absolute(staged_folder) # only if empty
		return older
	# A new file of a type downloaded before takes the older one's name.
	if older.get_extension() == target.get_extension():
		target = older
		older = ""
	# Moved already: a task can be handled twice.
	if not FileAccess.file_exists(path):
		return target if FileAccess.file_exists(target) else ""
	_keep_resource_uid(path, target)
	var moves := FileOps.Moves.new()
	var moved := moves.make_dir(folder) and moves.move(path, target)
	var dirs := DirAccess.get_directories_at(staged_folder)
	for dir in dirs:
		moved = moved and _move_dir(staged_folder.path_join(dir), folder.path_join(dir), moves)
	if not moved:
		moves.rollback()
		return ""
	moves.commit()
	if older:
		DirAccess.remove_absolute(older)
		DirAccess.remove_absolute(older + ".import")
	for dir in dirs:
		FileOps.remove_dir(staged_folder.path_join(dir)) # import settings not moved
	DirAccess.remove_absolute(staged_folder) # only if empty
	if id:
		_write_manifest(folder, id, base_id, target.get_file(), file_type)
	return target


## Give a text resource at [param path], like a converted material, the uid
## of the one at [param target] it replaces, so references to it keep
## working, or a new one. Godot keeps a text resource's uid in its header.
static func _keep_resource_uid(path: String, target: String) -> void:
	if path.get_extension() != "tres":
		return
	var text := FileAccess.get_file_as_string(path)
	var header := text.get_slice("\n", 0)
	if not header.begins_with("[gd_resource ") or header.contains(" uid=\""):
		return
	var uid := ""
	if FileAccess.file_exists(target):
		var m := _uid_regex.search(FileAccess.get_file_as_string(target).get_slice("\n", 0))
		uid = m.get_string(1) if m else ""
	if uid.is_empty():
		uid = ResourceUID.id_to_text(ResourceUID.create_id())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_string(header.trim_suffix("]") + " uid=\"%s\"]" % uid + text.substr(header.length()))


## Move the files in folder [param from] into folder [param to] with
## [param moves], replacing the files there, and keeping the others. Import
## settings there stay, with their uids and changes, else they move with
## their paths made project paths, see _localize_import_paths(). Returns
## whether all moved.
static func _move_dir(from: String, to: String, moves: FileOps.Moves) -> bool:
	if not moves.make_dir(to):
		return false
	for dir in DirAccess.get_directories_at(from):
		if not _move_dir(from.path_join(dir), to.path_join(dir), moves):
			return false
	for file in DirAccess.get_files_at(from):
		var target := to.path_join(file)
		if file.get_extension() == "import":
			if FileAccess.file_exists(target):
				continue
			_localize_import_paths(from.path_join(file), to)
		if not moves.move(from.path_join(file), target):
			return false
	return true


## Make the normal map path in the texture import settings at [param path]
## the project path of the normal map, from a path relative to folder
## [param dir] the texture moves to, see material_to_godot.py.
static func _localize_import_paths(path: String, dir: String) -> void:
	var config := ConfigFile.new()
	if config.load(path) != OK:
		return
	var normal: String = config.get_value("params", "roughness/src_normal", "")
	if normal.is_empty() or normal.is_absolute_path():
		return
	config.set_value("params", "roughness/src_normal", ProjectSettings.localize_path(dir.path_join(normal).simplify_path()))
	config.save(path)


## The folder in [param type_dir] for a download of asset [param id]: the one
## with this version already, else as [param uuid_names] says. Full keeps the
## Client's [param client_folder] name, short is <slug>_<short id>, and
## strip is <slug>, which an older version of the same asset is replaced in.
## Taken by another asset, the id is added, short then whole.
static func destination_folder(type_dir: String, client_folder: String, slug: String, id: String, base_id: String, uuid_names: String) -> String:
	var found := find_folder(type_dir, client_folder, slug, id, base_id)
	if found:
		return found
	var name := slug if slug else NAMELESS_SLUG
	var whole := "%s_%s" % [name, id]
	var names: Array
	match uuid_names:
		UUID_NAMES_SHORT:
			names = ["%s_%s" % [name, short_id(id)]]
		UUID_NAMES_STRIP:
			names = [name, "%s_%s" % [name, short_id(base_id if base_id else id)]]
		_:
			return type_dir.path_join(client_folder)
	for candidate in names:
		var path := type_dir.path_join(candidate)
		if _can_take(path, base_id if uuid_names == UUID_NAMES_STRIP else ""):
			return path
	return type_dir.path_join(whole)


## The folder in [param type_dir] with version [param id] of the asset,
## named in any of the ways destination_folder() names them, or "".
static func find_folder(type_dir: String, client_folder: String, slug: String, id: String, base_id: String = "") -> String:
	if id.is_empty():
		return ""
	var name := slug if slug else NAMELESS_SLUG
	var names := [client_folder, name, "%s_%s" % [name, short_id(id)], "%s_%s" % [name, id]]
	if base_id:
		names.append("%s_%s" % [name, short_id(base_id)])
	for candidate in names:
		var path := type_dir.path_join(candidate)
		if DirAccess.dir_exists_absolute(path) and folder_id(path) == id:
			return path
	return ""


## The folder in the download directory with the [param asset]'s version,
## or "".
static func asset_folder(abs_download_path: String, asset: Dictionary) -> String:
	var client_dir := GalleryApi.asset_download_dir(abs_download_path, asset)
	return find_folder(client_dir.get_base_dir(), client_dir.get_file(), GalleryApi.slugify(str(asset.get("name", ""))),
		str(asset.get("id", "")), GalleryApi.base_id(asset))


## Whether a download can go into the folder: it's new or empty, or it has
## another version of the asset with [param base_id].
static func _can_take(path: String, base_id: String) -> bool:
	if not DirAccess.dir_exists_absolute(path):
		return true
	var manifest := read_manifest(path)
	if manifest.is_empty():
		return DirAccess.get_files_at(path).is_empty() and DirAccess.get_directories_at(path).is_empty()
	return not base_id.is_empty() and manifest.assetBaseId == base_id


## The name of a file the Client downloaded, with the file id as
## [param uuid_names] says: chair_gltf_godot_<id>.glb stays in full,
## becomes chair_gltf_godot_<short id>.glb in short and chair_gltf_godot.glb
## in strip. Other names stay.
static func renamed_file(file_name: String, uuid_names: String) -> String:
	var m := _download_file_regex.search(file_name)
	if not m or uuid_names == UUID_NAMES_FULL:
		return file_name
	var parts := [m.get_string(1) if m.get_string(1) else NAMELESS_SLUG]
	if m.get_string(2):
		parts.append(m.get_string(2))
	if uuid_names == UUID_NAMES_SHORT:
		parts.append(short_id(m.get_string(3)))
	return "_".join(parts) + "." + m.get_string(4)


static func short_id(id: String) -> String:
	return id.left(SHORT_ID_LENGTH)


## The folder's manifest: {id, assetBaseId, files: {file name: fileType},
## versions: {file name: asset id}}, or {} if it has none. The id is the
## latest version downloaded into the folder, files listed by a manifest
## without versions are of that one.
static func read_manifest(folder: String) -> Dictionary:
	var path := folder.path_join(MANIFEST_FILE)
	var config := ConfigFile.new()
	if not FileAccess.file_exists(path) or config.load(path) != OK:
		return {}
	var id := str(config.get_value(MANIFEST_SECTION, "id", ""))
	var files = config.get_value(MANIFEST_SECTION, "files", {})
	if not files is Dictionary:
		files = {}
	var versions = config.get_value(MANIFEST_SECTION, "versions", {})
	if not versions is Dictionary:
		versions = {}
	for name in files:
		if not versions.has(name):
			versions[name] = id
	return {"id": id, "assetBaseId": str(config.get_value(MANIFEST_SECTION, "assetBaseId", "")),
		"files": files, "versions": versions}


## Note the downloaded file in the folder's manifest, now with version
## [param id] of the asset, and forget the files that are gone.
static func _write_manifest(folder: String, id: String, base_id: String, file_name: String, file_type: String) -> void:
	var manifest := read_manifest(folder)
	var files: Dictionary = manifest.get("files", {})
	var versions: Dictionary = manifest.get("versions", {})
	for name in files.keys():
		if not FileAccess.file_exists(folder.path_join(name)):
			files.erase(name)
	for name in versions.keys():
		if not files.has(name):
			versions.erase(name)
	if file_type:
		files[file_name] = file_type
		versions[file_name] = id
	if base_id.is_empty() and manifest.get("id", "") == id:
		base_id = manifest.assetBaseId
	var config := ConfigFile.new()
	config.set_value(MANIFEST_SECTION, "id", id)
	if base_id:
		config.set_value(MANIFEST_SECTION, "assetBaseId", base_id)
	config.set_value(MANIFEST_SECTION, "files", files)
	config.set_value(MANIFEST_SECTION, "versions", versions)
	if config.save(folder.path_join(MANIFEST_FILE)) != OK:
		push_warning("Blendkit: Could not save %s" % folder.path_join(MANIFEST_FILE))


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
