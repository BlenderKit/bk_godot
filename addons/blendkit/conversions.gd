@tool
extends RefCounted
## Fixes for downloads Godot can't import as they are. Before a download
## moves into the project, Blender re-saves it in its staging folder in a
## form Godot reads, under the same name. Without Blender, or when it fails,
## the file moves as it is.
##
## Fixes are lossless and run whenever there's a Blender, so they have no
## setting. Conversions that change what a download gives, e.g. a material
## into a Godot material, would be opt-in.

const BlenderImport = preload("res://addons/blendkit/blender_import.gd")

## Blender runs it with {input_path, output_path, alpha}.
const RESAVE_EXR_SCRIPT := "res://addons/blendkit/blender/resave_exr.py"
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


## How to make the file at [param path] importable: {script, params}, with
## the converted file at params.output_path, or {} when Godot imports it.
static func plan(path: String) -> Dictionary:
	if path.get_extension().to_lower() != "exr":
		return {}
	var header := exr_header(path)
	if header.is_empty() or header.compression in EXR_READABLE_COMPRESSIONS:
		return {}
	return {"script": RESAVE_EXR_SCRIPT, "params": {"input_path": path,
		"output_path": output_path(path), "alpha": header.alpha}}


## The converted file next to [param path], e.g. sky.godot.exr for sky.exr.
static func output_path(path: String) -> String:
	return "%s.godot.%s" % [path.get_basename(), path.get_extension()]


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


## Replace [param target] with [param source], keeping [param target] if
## that fails. Returns whether it was replaced.
static func replace_file(source: String, target: String) -> bool:
	var backup := target + ".bk_old"
	if DirAccess.rename_absolute(target, backup) != OK:
		return false
	if DirAccess.rename_absolute(source, target) != OK:
		DirAccess.rename_absolute(backup, target)
		return false
	DirAccess.remove_absolute(backup)
	return true
