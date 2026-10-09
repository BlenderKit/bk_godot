@tool
extends RefCounted
## Gallery helpers: search query building, file selection and download paths
## (pure, unit tested), plus JSON POSTs to the Blendkit Client.

const MAX_RESULT_WINDOW := 10000
## Downloads land in this hidden folder of the download directory, which
## Godot doesn't scan, and move to their place once complete. That keeps the
## editor from importing partial files.
const STAGING_DIR := ".downloads"
## Leftover staging folders this old are no longer written to.
const STAGING_STALE_SECONDS := 60
## Download statuses while it runs. A gallery download ends as finished,
## error or cancelled.
const ACTIVE_DOWNLOAD := ["posting", "created", "progress"]

## Asset types the gallery offers, in OptionButton order. These match what
## Send to Godot can deliver.
const ASSET_TYPES := ["model", "material", "hdr", "scene", "printable"]
const ASSET_TYPE_LABELS := {
	"model": "Models",
	"material": "Materials",
	"hdr": "HDRs",
	"scene": "Scenes",
	"printable": "Printables",
}

## Sort options, in OptionButton order: [id, label].
const SORTS := [
	["relevance", "Relevance"],
	["newest", "Newest"],
	["updated", "Recently updated"],
	["popular", "Popular"],
	["best", "Best rated"],
]
const SORT_ORDERS := {
	"newest": "-created",
	"updated": "-last_blend_upload",
	"popular": "-score",
	"best": "-quality",
}

## Texture size of the resolution file types, in pixels.
const RESOLUTION_PIXELS := {
	"resolution_0_5K": 512,
	"resolution_1K": 1024,
	"resolution_2K": 2048,
	"resolution_4K": 4096,
	"resolution_8K": 8192,
}

## Downloadable file types in display order: [fileType, label].
const FILE_TYPES := [
	["gltf_godot", "glTF for Godot (.glb)"],
	["gltf", "glTF (.glb)"],
	["blend", "Blender original (.blend)"],
	["resolution_8K", "Blender 8K textures (.blend)"],
	["resolution_4K", "Blender 4K textures (.blend)"],
	["resolution_2K", "Blender 2K textures (.blend)"],
	["resolution_1K", "Blender 1K textures (.blend)"],
	["resolution_0_5K", "Blender 0.5K textures (.blend)"],
	["zip_file", "Archive (.zip)"],
]

static var _slug_regex := RegEx.create_from_string("[^a-z0-9]+")


## Index of [param value] in [code][value, label][/code] [param options],
## e.g. for an OptionButton; the first option when it's not there.
static func option_index(options: Array, value: Variant) -> int:
	for i in options.size():
		if options[i][0] == value:
			return i
	return 0


# MARK: query building

## Order for a sort option. Relevance needs text to rank by, so without text
## fall back to recently updated, like the Blender add-on.
static func search_order(sort: String, text: String) -> String:
	if SORT_ORDERS.has(sort):
		return SORT_ORDERS[sort]
	return "_score" if not text.strip_edges().is_empty() else "-last_blend_upload"


## Encode free text like Python's quote_plus: words are URI-encoded and
## joined with "+".
static func encode_text(text: String) -> String:
	var words := PackedStringArray()
	for word in text.split(" ", false):
		word = word.strip_edges()
		if not word.is_empty():
			words.append(word.uri_encode())
	return "+".join(words)


static func build_search_url(server: String, text: String, asset_type: String, category_slug: String, sort: String, free_only: bool, godot_ready: bool, page: int, page_size: int, addon_version: String) -> String:
	var tokens := PackedStringArray()
	var encoded := encode_text(text)
	if not encoded.is_empty():
		tokens.append(encoded)
	tokens.append("asset_type:" + asset_type)
	# category_subtree:<type> gives irrelevant results, so skip the root
	if not category_slug.is_empty() and category_slug != asset_type:
		tokens.append("category_subtree:" + category_slug.uri_encode())
	if free_only:
		tokens.append("is_free:true")
	if asset_type == "model":
		tokens.append("sexualizedContent:false")
		if godot_ready:
			tokens.append("last_gltf_godot_upload_isnull:false")
	tokens.append("order:" + search_order(sort, text))
	return "%s/api/v1/search/?query=%s&dict_parameters=1&page_size=%d&page=%d&addon_version=%s" % [
		server, "+".join(tokens), page_size, page, addon_version.uri_encode()]


## Search for one asset by its version id, as named in the asset's
## download folder.
static func build_lookup_url(server: String, asset_id: String, addon_version: String) -> String:
	return "%s/api/v1/search/?query=asset_id:%s&dict_parameters=1&page_size=1&addon_version=%s" % [
		server, asset_id.uri_encode(), addon_version.uri_encode()]


## Pages reachable by the server, which serves only the first 10000 results.
static func page_count(count: int, page_size: int) -> int:
	if count <= 0 or page_size <= 0:
		return 0
	return ceili(mini(count, MAX_RESULT_WINDOW) / float(page_size))


# MARK: files and paths

static func file_types(asset: Dictionary) -> PackedStringArray:
	var types := PackedStringArray()
	for f in asset.get("files", []):
		if f is Dictionary:
			types.append(str(f.get("fileType", "")))
	return types


## File types of the asset a user can choose to download, in display order.
static func downloadable_file_types(asset: Dictionary) -> PackedStringArray:
	var present := file_types(asset)
	var result := PackedStringArray()
	for entry in FILE_TYPES:
		if entry[0] in present:
			# the zip is only a fallback when no .blend exists
			if entry[0] == "zip_file" and "blend" in present:
				continue
			result.append(entry[0])
	return result


static func file_type_label(file_type: String) -> String:
	for entry in FILE_TYPES:
		if entry[0] == file_type:
			return entry[1]
	return file_type


## The fileType the Client would pick for Send to Godot, mirroring its
## selectAssetFile / GetResolutionFile. Passing it as the download resolution
## selects exactly that file.
static func pick_file_type(asset: Dictionary, model_format: String, resolution: String) -> String:
	var present := file_types(asset)
	if asset.get("assetType", "") == "model":
		var candidates: Array = []
		match model_format:
			"gltf_godot": candidates = ["gltf_godot", "gltf"]
			"gltf": candidates = ["gltf", "gltf_godot"]
		for ft in candidates:
			if ft in present:
				return ft
	return pick_resolution_file_type(present, resolution)


static func pick_resolution_file_type(present: PackedStringArray, resolution: String) -> String:
	if resolution == "ORIGINAL" and "blend" in present:
		return "blend"
	if not resolution.is_empty() and resolution in present:
		return resolution
	var target: int = RESOLUTION_PIXELS.get(resolution, 0)
	var closest := ""
	var min_dist := 100000000
	if target != 0:
		for ft in present:
			if RESOLUTION_PIXELS.has(ft):
				var dist: int = absi(target - RESOLUTION_PIXELS[ft])
				if dist < min_dist:
					closest = ft
					min_dist = dist
	if not closest.is_empty():
		return closest
	if "zip_file" in present:
		return "zip_file"
	return "blend"


## Mirrors the Client's Slugify.
static func slugify(text: String) -> String:
	var slug := _slug_regex.sub(text.to_lower(), "-", true)
	if slug.length() > 50:
		slug = slug.left(50)
	return slug.lstrip("-").rstrip("-")


static func plural_asset_type(asset_type: String) -> String:
	return "brushes" if asset_type == "brush" else asset_type + "s"


## Directory the Client downloads into for download dir <abs>/<type>s, the
## same layout as Send to Godot: <abs>/<type>s/<slug16>_<id>.
static func asset_download_dir(abs_download_path: String, asset: Dictionary) -> String:
	var slug := slugify(str(asset.get("name", "")))
	if slug.length() > 16:
		slug = slug.left(16)
	return type_download_dir(abs_download_path, str(asset.get("assetType", ""))).path_join(
		"%s_%s" % [slug, str(asset.get("id", ""))])


static func type_download_dir(abs_download_path: String, asset_type: String) -> String:
	return abs_download_path.path_join(plural_asset_type(asset_type))


# MARK: staging

## Where the Client downloads for download dir [param abs_download_path],
## with the same layout.
static func staging_path(abs_download_path: String) -> String:
	return abs_download_path.path_join(STAGING_DIR)


## Create the staging folder, kept out of version control.
static func ensure_staging(abs_download_path: String) -> void:
	var staging := staging_path(abs_download_path)
	DirAccess.make_dir_recursive_absolute(staging)
	var ignore := staging.path_join(".gitignore")
	if not FileAccess.file_exists(ignore):
		var file := FileAccess.open(ignore, FileAccess.WRITE)
		if file:
			file.store_string("# Blendkit downloads in progress\n*\n")


## Where a file downloaded to the staging folder belongs. Paths outside it
## are returned as they are. The Client reports native paths, so Windows
## backslashes become slashes.
static func unstaged_path(path: String) -> String:
	path = path.replace("\\", "/")
	var marker := "/" + STAGING_DIR + "/"
	var i := path.rfind(marker)
	return path if i < 0 else path.left(i) + path.substr(i + marker.length() - 1)


## Move a finished download from the staging folder to its place, replacing
## an older copy there, whose .import and .uid stay so references keep
## working. Returns the new path; "" if the move failed.
static func finish_download(path: String) -> String:
	path = path.replace("\\", "/")
	var target := unstaged_path(path)
	# Not staged, or moved already (a task can be handled twice).
	if target == path or not FileAccess.file_exists(path):
		return target
	DirAccess.make_dir_recursive_absolute(target.get_base_dir())
	if FileAccess.file_exists(target) and DirAccess.remove_absolute(target) != OK:
		return ""
	if DirAccess.rename_absolute(path, target) != OK:
		return ""
	DirAccess.remove_absolute(path.get_base_dir()) # only if empty
	return target


## Delete asset folders left in the staging folder, e.g. by downloads the
## editor closed during, except those in [param keep] and ones still being
## written to. Returns how many were deleted.
static func clear_staging(abs_download_path: String, keep: Dictionary) -> int:
	var staging := staging_path(abs_download_path)
	var now := int(Time.get_unix_time_from_system())
	var cleared := 0
	if not DirAccess.dir_exists_absolute(staging):
		return cleared
	for type_name in DirAccess.get_directories_at(staging):
		var type_dir := staging.path_join(type_name)
		for folder in DirAccess.get_directories_at(type_dir):
			var path := type_dir.path_join(folder)
			if keep.has(path):
				continue
			var files := DirAccess.get_files_at(path)
			var newest := FileAccess.get_modified_time(path)
			for file in files:
				newest = maxi(newest, FileAccess.get_modified_time(path.path_join(file)))
			if now - newest < STAGING_STALE_SECONDS:
				continue
			for file in files:
				DirAccess.remove_absolute(path.path_join(file))
			if DirAccess.remove_absolute(path) == OK:
				cleared += 1
	return cleared


static func web_url(server: String, asset: Dictionary) -> String:
	return "%s/asset-gallery-detail/%s/" % [server, str(asset.get("assetBaseId", ""))]


static func author_name(asset: Dictionary) -> String:
	var author = asset.get("author", {})
	if not author is Dictionary:
		return ""
	var full := str(author.get("fullName", "")).strip_edges()
	if not full.is_empty():
		return full
	return ("%s %s" % [author.get("firstName", ""), author.get("lastName", "")]).strip_edges()


## Message explaining why the asset can't be downloaded, or "".
static func cant_download_message(asset: Dictionary) -> String:
	var err = asset.get("canDownloadError")
	if err is Dictionary:
		var messages = err.get("messages", [])
		if messages is Array and not messages.is_empty():
			return " ".join(PackedStringArray(messages.map(func(m): return str(m))))
	return ""


static func new_uuid4() -> String:
	var b := Crypto.new().generate_random_bytes(16)
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	var h := b.hex_encode()
	return "%s-%s-%s-%s-%s" % [h.substr(0, 8), h.substr(8, 4), h.substr(12, 4), h.substr(16, 4), h.substr(20, 12)]


## One UUID per project, kept in the editor's project metadata so it doesn't
## end up in project.godot.
static func project_scene_uuid() -> String:
	var settings := EditorInterface.get_editor_settings()
	var uuid := str(settings.get_project_metadata("blendkit", "scene_uuid", ""))
	if uuid.length() != 36:
		uuid = new_uuid4()
		settings.set_project_metadata("blendkit", "scene_uuid", uuid)
	return uuid


## Thumbnails live outside the project so Godot never imports them.
static func search_temp_dir(client_data_dir: String, asset_type: String) -> String:
	return client_data_dir.get_base_dir().path_join("godot_temp").path_join("%s_search" % asset_type)


# MARK: Client requests

## POST JSON with a short-lived HTTPRequest under parent. Returns
## {"ok": bool, "code": int, "data": Variant, "error": String}.
static func post_json(parent: Node, url: String, body: Dictionary, timeout: float = 10.0) -> Dictionary:
	var request := HTTPRequest.new()
	request.timeout = timeout
	parent.add_child(request)
	var err := request.request(url, ["Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify(whole_floats_to_ints(body)))
	if err != OK:
		request.queue_free()
		return {"ok": false, "code": 0, "data": null, "error": "request error %d" % err}
	var response: Array = await request.request_completed
	request.queue_free()
	var result: int = response[0]
	var code: int = response[1]
	var text: String = response[3].get_string_from_utf8()
	if result != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "code": code, "data": null, "error": "connection failed (%d)" % result}
	# JSON.parse_string() would log an engine error for plain-text errors
	var json := JSON.new()
	var data = json.data if json.parse(text) == OK else null
	if code != 200:
		var msg := text.strip_edges()
		if data is Dictionary and data.has("detail"):
			msg = str(data["detail"])
		return {"ok": false, "code": code, "data": data, "error": "HTTP %d: %s" % [code, msg.left(200)]}
	return {"ok": true, "code": code, "data": data, "error": ""}


## Godot parses all JSON numbers as floats and writes whole floats as "1.0",
## which the Client's integer fields (e.g. fileUploadSize) reject.
static func whole_floats_to_ints(value: Variant) -> Variant:
	match typeof(value):
		TYPE_FLOAT:
			if value == floorf(value) and absf(value) < 9.0e15:
				return int(value)
		TYPE_DICTIONARY:
			var result := {}
			for key in value:
				result[key] = whole_floats_to_ints(value[key])
			return result
		TYPE_ARRAY:
			return value.map(whole_floats_to_ints)
	return value


## Returns [task_id, error]; task_id is "" on failure.
static func task_id_from(response: Dictionary) -> Array:
	if not response.ok:
		return ["", response.error]
	if response.data is Dictionary and response.data.has("task_id"):
		return [str(response.data.task_id), ""]
	return ["", "unexpected Client response"]


## The requests below go through [param plugin]'s Client connection and run
## under [param parent], which they don't outlive.
static func search(parent: Node, plugin: EditorPlugin, url_query: String, asset_type: String, tempdir: String, page_size: int) -> Array:
	DirAccess.make_dir_recursive_absolute(tempdir)
	var body: Dictionary = plugin.client_data(plugin.auth.api_key())
	body.merge({
		"asset_type": asset_type,
		"urlquery": url_query,
		"tempdir": tempdir,
		"page_size": page_size,
		"scene_uuid": project_scene_uuid(),
	})
	return task_id_from(await post_json(parent, plugin.client_url("assets/search"), body))


static func download(parent: Node, plugin: EditorPlugin, asset: Dictionary, file_type: String, abs_download_path: String) -> Array:
	var body := {
		"app_id": OS.get_process_id(),
		"addon_version": plugin.get_addon_version(),
		"platform_version": OS.get_name(),
		"download_dirs": [type_download_dir(abs_download_path, str(asset.get("assetType", "")))],
		"resolution": file_type,
		"asset_data": {
			"name": asset.get("name", ""),
			"id": str(asset.get("id", "")),
			"assetType": asset.get("assetType", ""),
			"files": asset.get("files", []),
			"available_resolutions": [],
		},
		"PREFS": {
			"scene_id": project_scene_uuid(),
			"api_key": plugin.auth.api_key(),
			"unpack_files": false,
			"create_asset_library": false,
		},
	}
	return task_id_from(await post_json(parent, plugin.client_url("assets/download"), body))


static func cancel_download(parent: Node, plugin: EditorPlugin, task_id: String) -> Dictionary:
	var body := {"task_id": task_id, "app_id": OS.get_process_id()}
	return await post_json(parent, plugin.client_url("assets/cancel_download"), body)


## Fallback for a missed categories_update task. Returns the category tree
## (top-level entries per asset type) or [].
static func fetch_categories(parent: Node, plugin: EditorPlugin) -> Array:
	var body := {"url": plugin.SERVER + "/api/v1/categories/", "method": "GET", "headers": {}}
	var response := await post_json(parent, plugin.client_url("wrappers/blocking_request"), body, 30.0)
	if response.ok and response.data is Dictionary and response.data.get("results") is Array:
		return response.data.results
	return []


# MARK: files from tasks

static func load_texture(path: String) -> Texture2D:
	var image := load_image(path)
	return ImageTexture.create_from_image(image) if image else null


## Image.load() picks the decoder by extension, but the client's cached files
## don't always match theirs (e.g. PNG avatars saved as .jpg), so sniff the
## format from the file's first bytes instead.
static func load_image(path: String) -> Image:
	if path.is_empty() or not FileAccess.file_exists(path):
		return null
	var bytes := FileAccess.get_file_as_bytes(path)
	var image := Image.new()
	var err := ERR_FILE_UNRECOGNIZED
	if bytes.size() >= 8 and bytes.slice(0, 8) == PackedByteArray([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]):
		err = image.load_png_from_buffer(bytes)
	elif bytes.size() >= 3 and bytes.slice(0, 3) == PackedByteArray([0xFF, 0xD8, 0xFF]):
		err = image.load_jpg_from_buffer(bytes)
	elif bytes.size() >= 12 and bytes.slice(0, 4).get_string_from_ascii() == "RIFF" and bytes.slice(8, 12).get_string_from_ascii() == "WEBP":
		err = image.load_webp_from_buffer(bytes)
	return image if err == OK else null


## Path of the downloaded file from a finished asset_download task.
## /assets/download reports file_paths, Send to Godot reports file_path.
static func task_file_path(task: Dictionary) -> String:
	var result = task.get("result")
	if not result is Dictionary:
		return ""
	if result.get("file_path"):
		return str(result.file_path)
	var paths = result.get("file_paths")
	if paths is Array and not paths.is_empty():
		return str(paths[0])
	return ""
