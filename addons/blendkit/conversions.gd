@tool
extends RefCounted
## Conversions of downloads Godot can't use as they are. Before a download
## moves into the project, Blender converts it in its staging folder into
## a form Godot reads: an EXR it can't read is re-saved under the same name,
## and a material .blend becomes a Godot material with its textures. Without
## Blender, or when it fails, the file moves as it is.
##
## Conversions run whenever there's a Blender, so they have no setting: what
## they replace is of no use in Godot.

const BlenderImport = preload("res://addons/blendkit/blender_import.gd")

## Blender runs it with {input_path, output_path, alpha}.
const RESAVE_EXR_SCRIPT := "res://addons/blendkit/blender/resave_exr.py"
## Blender runs it with {input_path, output_path, textures_dir}.
const MATERIAL_SCRIPT := "res://addons/blendkit/blender/material_to_godot.py"
## The download folder of materials, see GalleryApi.plural_asset_type().
const MATERIALS_DIR := "materials"
const EXR_MAGIC := 20000630
## Version flags of multi-part and deep data files, which aren't converted.
const EXR_MULTIPART_OR_DEEP := 0x1800
## Compressions Godot's EXR loader (tinyexr) reads: none, RLE, ZIPS, ZIP and
## PIZ. It fails on the others, e.g. the lossy DWAA of Blendkit's HDRs.
const EXR_READABLE_COMPRESSIONS := [0, 1, 2, 3, 4]
## Header attributes are read up to this size, to bail out of broken files.
const EXR_MAX_ATTRIBUTE := 1 << 16
const MESSAGE := "Converting for Godot"

## The Blender found on this computer, "" for none, null before looking.
static var _detected: Variant = null
static var _detecting := false


## How to make the file at [param path] of use in Godot: {script, params,
## file, dirs}, or {} when Godot imports it as it is. The script writes
## params.output_path, which becomes [code]file[/code]: the file the download
## is then, at [param path] when the conversion replaces it. [code]dirs[/code]
## are folders the script writes too.
static func plan(path: String) -> Dictionary:
	match path.get_extension().to_lower():
		"exr":
			var header := exr_header(path)
			if header.is_empty() or header.compression in EXR_READABLE_COMPRESSIONS:
				return {}
			return {"script": RESAVE_EXR_SCRIPT, "params": {"input_path": path,
				"output_path": output_path(path), "alpha": header.alpha}, "file": path, "dirs": []}
		"blend":
			if path.get_base_dir().get_base_dir().get_file() != MATERIALS_DIR:
				return {}
			var material := path.get_basename() + ".tres"
			var textures := path.get_base_dir().path_join(textures_dir_name(path))
			return {"script": MATERIAL_SCRIPT, "params": {"input_path": path,
				"output_path": material, "textures_dir": textures}, "file": material, "dirs": [textures]}
	return {}


## The converted file next to [param path], e.g. sky.godot.exr for sky.exr.
static func output_path(path: String) -> String:
	return "%s.godot.%s" % [path.get_basename(), path.get_extension()]


## The folder for the textures of a material converted from the file at
## [param path], named after its resolution so that the materials of each
## stay apart in the asset folder: textures_2K for
## wood_2K_<file id>.blend, textures for wood_<file id>.blend.
static func textures_dir_name(path: String) -> String:
	var name := path.get_file().get_basename()
	var first := name.find("_")
	var last := name.rfind("_")
	if first < 0 or last <= first:
		return "textures"
	return "textures_" + name.substr(first + 1, last - first - 1)


## The compression code and whether there's an alpha channel, from the
## header of a single-part OpenEXR file. {} for other and broken files.
static func exr_header(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if not file or file.get_length() < 8 or file.get_32() != EXR_MAGIC:
		return {}
	if file.get_32() & EXR_MULTIPART_OR_DEEP:
		return {}
	var result := {"compression": -1, "alpha": false}
	while true:
		var attribute := _read_name(file)
		if attribute.is_empty():
			break # end of the header, or broken
		_read_name(file) # type
		var size := file.get_32()
		if file.eof_reached() or size > EXR_MAX_ATTRIBUTE:
			return {}
		var end := file.get_position() + size
		match attribute:
			"compression":
				result.compression = file.get_8()
			"channels":
				# name, then pixel type, linear, reserved and sampling
				var channel := _read_name(file)
				while not channel.is_empty() and file.get_position() < end:
					if channel == "A":
						result.alpha = true
					file.get_buffer(16)
					channel = _read_name(file)
		file.seek(end)
	return result if result.compression >= 0 else {}


## A null-terminated name of at most 255 bytes, "" at its end or the file's.
static func _read_name(file: FileAccess) -> String:
	var bytes := PackedByteArray()
	while bytes.size() < 256:
		var byte := file.get_8()
		if byte == 0 or file.eof_reached():
			return bytes.get_string_from_utf8()
		bytes.append(byte)
	return ""


## The Blender to convert with: Godot's Blender for .blend import, else the
## newest one found on this computer, else "" to let the Client use one
## another plugin told it about. Finding one runs each candidate, so it's
## done once per editor session, on a thread.
static func blender_path() -> String:
	var path := BlenderImport.blender_path()
	if not path.is_empty() and FileAccess.file_exists(path):
		return path
	var tree := Engine.get_main_loop() as SceneTree
	while _detecting:
		await tree.process_frame
	if _detected == null:
		_detecting = true
		var found: Array[Dictionary] = []
		var task := WorkerThreadPool.add_task(func(): found.append_array(BlenderImport.detect()))
		while not WorkerThreadPool.is_task_completed(task):
			await tree.process_frame
		WorkerThreadPool.wait_for_task_completion(task)
		_detected = found[0].path if not found.is_empty() else ""
		_detecting = false
	return _detected


## Look for a Blender again next time, e.g. after one was installed. A
## detection running meanwhile still answers those waiting for it.
static func forget_detected() -> void:
	if not _detecting:
		_detected = null

