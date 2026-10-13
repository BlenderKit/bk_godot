"""Tests for making downloads importable with Blender before they move into
the project."""

import json
import os
import shutil
import subprocess

import pytest

from .conftest import ADDON_DIR, make_probe_project, run_editor_probe, run_godot_script


# Writes an OpenEXR header with the given compression and channels, and a few
# bytes standing in for the pixels.
EXR_WRITER = r"""
func exr(path: String, compression: int, channels: Array, flags: int = 2) -> void:
    var f := FileAccess.open(path, FileAccess.WRITE)
    f.store_32(20000630)
    f.store_32(flags)
    var list := PackedByteArray()
    for channel in channels:
        list.append_array(channel.to_utf8_buffer())
        list.append(0)
        # half, linear, reserved, x and y sampling
        list.append_array(PackedByteArray([1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]))
    list.append(0)
    attribute(f, "channels", "chlist", list)
    attribute(f, "compression", "compression", PackedByteArray([compression]))
    f.store_8(0)
    f.store_buffer(PackedByteArray([1, 2, 3]))

func attribute(f: FileAccess, name: String, type: String, value: PackedByteArray) -> void:
    f.store_buffer(name.to_utf8_buffer())
    f.store_8(0)
    f.store_buffer(type.to_utf8_buffer())
    f.store_8(0)
    f.store_32(value.size())
    f.store_buffer(value)
"""


CONVERSIONS_CHECKS = (
    r"""extends SceneTree

const Conversions = preload("res://addons/blendkit/conversions.gd")

var failures := 0

func check(ok: bool, what: String) -> void:
    if not ok:
        failures += 1
        print("CHECK FAILED: " + what)
"""
    + EXR_WRITER
    + r"""
func _initialize():
    var dir := OS.get_environment("BK_TEST_DIR")
    DirAccess.make_dir_recursive_absolute(dir)
    var dwaa := dir.path_join("sky_2K.exr")
    exr(dwaa, 8, ["B", "G", "R"])
    check(Conversions.exr_header(dwaa) == {"compression": 8, "alpha": false}, str(Conversions.exr_header(dwaa)))
    var plan := Conversions.plan(dwaa)
    check(plan.get("script") == Conversions.RESAVE_EXR_SCRIPT, str(plan))
    check(plan.get("params") == {"input_path": dwaa, "output_path": dir.path_join("sky_2K.godot.exr"), "alpha": false}, str(plan))
    # the extension's case doesn't matter, the alpha channel is kept
    var upper := dir.path_join("decal.EXR")
    exr(upper, 9, ["A", "B", "G", "R"])
    check(Conversions.plan(upper).get("params", {}).get("alpha") == true, str(Conversions.plan(upper)))
    check(Conversions.output_path(upper) == dir.path_join("decal.godot.EXR"), Conversions.output_path(upper))
    # Godot reads these as they are
    for compression in [0, 1, 2, 3, 4]:
        var readable := dir.path_join("readable_%d.exr" % compression)
        exr(readable, compression, ["B", "G", "R"])
        check(Conversions.plan(readable).is_empty(), "readable %d" % compression)
    # multi-part, broken, missing and other files aren't converted
    var multipart := dir.path_join("multipart.exr")
    exr(multipart, 8, ["B", "G", "R"], 0x1002)
    check(Conversions.exr_header(multipart).is_empty(), "multi-part")
    var truncated := dir.path_join("truncated.exr")
    var bytes := FileAccess.get_file_as_bytes(dwaa)
    FileAccess.open(truncated, FileAccess.WRITE).store_buffer(bytes.slice(0, 30))
    check(Conversions.plan(truncated).is_empty(), "truncated")
    var not_exr := dir.path_join("fake.exr")
    FileAccess.open(not_exr, FileAccess.WRITE).store_string("not an image at all")
    check(Conversions.plan(not_exr).is_empty(), "not an EXR")
    check(Conversions.plan(dir.path_join("missing.exr")).is_empty(), "missing")
    var hdr := dir.path_join("sky.hdr")
    FileAccess.open(hdr, FileAccess.WRITE).store_string("#?RADIANCE\n")
    check(Conversions.plan(hdr).is_empty(), "Radiance HDR")

    # Material .blend files become Godot materials with their textures.
    var materials := dir.path_join("materials/rock-road_0000")
    var blend := materials.path_join("rock-road_2K_6c02715d-2e81-4a9a-ae57-a961f7d3cc37.blend")
    plan = Conversions.plan(blend)
    var material := materials.path_join("rock-road_2K_6c02715d-2e81-4a9a-ae57-a961f7d3cc37.tres")
    check(plan == {"script": Conversions.MATERIAL_SCRIPT, "params": {"input_path": blend, "output_path": material,
        "textures_dir": materials.path_join("textures_2K")}, "file": material,
        "dirs": [materials.path_join("textures_2K")]}, str(plan))
    check(Conversions.plan(dir.path_join("models/chair_0000/chair_2K.blend")).is_empty(), "model .blend")
    check(Conversions.plan("C:\\bk\\materials\\rock_0000\\rock_2K.blend").get("file") == "C:\\bk\\materials\\rock_0000\\rock_2K.tres", "Windows path")
    check(Conversions.textures_dir_name("rock_0_5K_6c02715d-2e81-4a9a-ae57-a961f7d3cc37.blend") == "textures_0_5K", "0.5K")
    check(Conversions.textures_dir_name("rock_6c02715d-2e81-4a9a-ae57-a961f7d3cc37.blend") == "textures", "original")
    check(Conversions.textures_dir_name("rock.blend") == "textures", "other name")

    # The converted file takes the original's place.
    var target := dir.path_join("target.exr")
    var source := dir.path_join("target.godot.exr")
    FileAccess.open(target, FileAccess.WRITE).store_string("original")
    FileAccess.open(source, FileAccess.WRITE).store_string("converted")
    check(Conversions.replace_file(source, target), "replaced")
    check(FileAccess.get_file_as_string(target) == "converted", "converted content")
    check(not FileAccess.file_exists(source) and not FileAccess.file_exists(target + ".bk_old"), "no leftovers")
    # Without a converted file, the original stays.
    check(not Conversions.replace_file(source, target), "nothing to replace with")
    check(FileAccess.get_file_as_string(target) == "converted", "kept")
    check(not FileAccess.file_exists(target + ".bk_old"), "backup restored")

    if failures == 0:
        print("CONVERSIONS_CHECKS_PASSED")
    quit(1 if failures else 0)
"""
)


def test_conversions(godot_executable, tmp_path):
    env = {"BK_TEST_DIR": (tmp_path / "data").as_posix()}
    result = run_godot_script(godot_executable, tmp_path, CONVERSIONS_CHECKS, env)
    output = result.stdout + result.stderr
    assert result.returncode == 0, output
    assert "CONVERSIONS_CHECKS_PASSED" in result.stdout, output
    assert "SCRIPT ERROR" not in result.stderr, output


CONVERSION_PROBE = (
    r"""
const GalleryApi = preload("res://addons/blendkit/ui/gallery/gallery_api.gd")
const Conversions = preload("res://addons/blendkit/conversions.gd")
const DWAA := 8
const ZIP := 3
"""
    + EXR_WRITER
    + r"""
var posts := []
## How the mocked conversions go: "convert" writes the converted file,
## "fail" doesn't and "no_blender" fails to start.
var mode := "convert"

func asset(n: int) -> Dictionary:
    return {"id": "0000000%d-2390-4999-83d7-c72ea929f352" % n, "assetBaseId": "base-%d" % n,
        "name": "Sky %d" % n, "assetType": "hdr", "canDownload": true,
        "files": [{"fileType": "resolution_2K", "downloadUrl": "x"}]}

## A downloaded EXR in the staging folder of [param a].
func staged(gallery, a: Dictionary, compression: int) -> String:
    var staging := GalleryApi.staging_path(gallery.plugin.absolute_download_path)
    var folder := GalleryApi.asset_download_dir(staging, a)
    DirAccess.make_dir_recursive_absolute(folder)
    var path := folder.path_join("sky_2K.exr")
    exr(path, compression, ["B", "G", "R"])
    return path

func compression(path: String) -> int:
    return Conversions.exr_header(path).get("compression", -1)

func state(gallery, base_id: String) -> String:
    var dl: Dictionary = gallery.downloads.get_download(base_id)
    return "%s|%s" % [dl.status, dl.message]

## Download asset [param n] with a file of [param compression], and report
## its conversion as [param report], if any. Prints what happened.
func download(gallery, n: int, file_compression: int, report: String) -> void:
    var a := asset(n)
    var path := staged(gallery, a, file_compression)
    posts.clear()
    await gallery.downloads.start(a, "resolution_2K")
    gallery.handle_task({"task_type": "asset_download", "task_id": "task-%d" % n, "status": "finished",
        "result": {"file_paths": [path]}})
    print("CASE%d=%s ACTIVE=%d POSTS=%d" % [n, state(gallery, a.assetBaseId), gallery.downloads.active_count(), posts.size()])
    if report:
        gallery.handle_task({"task_type": "run_blender_script", "task_id": "conv-%d" % posts.size(),
            "status": report, "message": "script produced no output"})
    await wait_until(func(): return gallery.downloads.get_download(a.assetBaseId).status == "finished", 5)
    var dl: Dictionary = gallery.downloads.get_download(a.assetBaseId)
    print("CASE%d_DONE=%s POSTS=%d COMPRESSION=%d LEFT=%s" % [n, dl.status, posts.size(),
        compression(dl.file_path), DirAccess.dir_exists_absolute(path.get_base_dir())])

func check():
    var gallery = find_gallery()
    var downloads = gallery.downloads
    downloads.post_download = func(a: Dictionary, _file_type: String) -> Array:
        return ["task-%s" % a.assetBaseId.get_slice("-", 1), ""]
    downloads.post_conversion = func(plan: Dictionary) -> Array:
        posts.append(plan)
        if mode == "no_blender":
            return ["", "Blender not found"]
        if mode == "convert":
            exr(plan.params.output_path, ZIP, ["B", "G", "R"])
        return ["conv-%d" % posts.size(), ""]
    # Converted, the file moves into the project as ZIP.
    await download(gallery, 1, DWAA, "finished")
    # A failed conversion moves the original.
    mode = "fail"
    await download(gallery, 2, DWAA, "error")
    mode = "no_blender"
    await download(gallery, 3, DWAA, "")
    # A file Godot reads moves without converting.
    mode = "convert"
    await download(gallery, 4, ZIP, "")

    # Disconnected, the conversion stops waiting and the original moves.
    var a := asset(5)
    var path := staged(gallery, a, DWAA)
    await downloads.start(a, "resolution_2K")
    gallery.handle_task({"task_type": "asset_download", "task_id": "task-5", "status": "finished",
        "result": {"file_paths": [path]}})
    downloads.on_disconnected()
    gallery.tasks.cancel_all()
    print("DISCONNECTED=%s" % state(gallery, a.assetBaseId))
    await wait_until(func(): return downloads.get_download(a.assetBaseId).status == "finished", 5)
    print("DISCONNECTED_DONE=%s COMPRESSION=%d" % [downloads.get_download(a.assetBaseId).status,
        compression(downloads.get_download(a.assetBaseId).file_path)])

    # A Send to Godot download shows converting until it moves.
    var web := asset(6)
    var web_path := staged(gallery, web, DWAA)
    gallery.handle_task({"task_type": "asset_download", "task_id": "web-1", "status": "progress", "progress": 90})
    posts.clear()
    gallery.handle_task({"task_type": "asset_download", "task_id": "web-1", "status": "finished",
        "result": {"file_path": web_path}})
    print("WEB=%s|%s POSTS=%d" % [downloads.web_downloads["web-1"].status, downloads.web_downloads["web-1"].message, posts.size()])
    gallery.drop_vanished_downloads({})
    print("WEB_KEPT=%d" % downloads.web_downloads.size())
    gallery.handle_task({"task_type": "run_blender_script", "task_id": "conv-1", "status": "finished"})
    await wait_until(func(): return downloads.web_downloads.is_empty(), 5)
    var moved: String = gallery.plugin.absolute_download_path.path_join("hdrs/sky-6/sky_2K.exr")
    print("WEB_DONE=%d COMPRESSION=%d" % [downloads.web_downloads.size(), compression(moved)])
"""
)


def test_download_conversion(godot_executable, tmp_path):
    """Finished downloads Godot can't import are converted in staging, and
    move as they are when that fails."""
    project = make_probe_project(tmp_path / "project", CONVERSION_PROBE)
    stdout, stderr = run_editor_probe(godot_executable, project)
    output = stdout + stderr
    lines = stdout.splitlines()
    assert "CASE1=converting|Converting for Godot ACTIVE=1 POSTS=1" in lines, output
    assert "CASE1_DONE=finished POSTS=1 COMPRESSION=3 LEFT=false" in lines, output
    assert "CASE2_DONE=finished POSTS=1 COMPRESSION=8 LEFT=false" in lines, output
    assert "CASE3_DONE=finished POSTS=1 COMPRESSION=8 LEFT=false" in lines, output
    assert "CASE4=finished| ACTIVE=0 POSTS=0" in lines, output
    assert "CASE4_DONE=finished POSTS=0 COMPRESSION=3 LEFT=false" in lines, output
    assert "DISCONNECTED=converting|Converting for Godot" in lines, output
    assert "DISCONNECTED_DONE=finished COMPRESSION=8" in lines, output
    assert "WEB=converting|Converting for Godot POSTS=1" in lines, output
    assert "WEB_KEPT=1" in lines, output
    assert "WEB_DONE=0 COMPRESSION=3" in lines, output
    assert "Could not convert sky_2K.exr for Godot, which may not import it: script produced no output" in stderr, output
    assert "Could not convert sky_2K.exr for Godot, which may not import it: Blender not found" in stderr, output
    assert "Could not convert sky_2K.exr for Godot, which may not import it: Blendkit Client disconnected" in stderr, output
    assert "SCRIPT ERROR" not in stderr, output


MATERIAL_PROBE = r"""
const GalleryApi = preload("res://addons/blendkit/ui/gallery/gallery_api.gd")

var mode := "convert"

func asset(n: int) -> Dictionary:
    return {"id": "0000000%d-2390-4999-83d7-c72ea929f352" % n, "assetBaseId": "base-%d" % n,
        "name": "Rock Road %d" % n, "assetType": "material", "canDownload": true,
        "files": [{"fileType": "resolution_2K", "downloadUrl": "x"}]}

func write(path: String, text: String) -> void:
    DirAccess.make_dir_recursive_absolute(path.get_base_dir())
    FileAccess.open(path, FileAccess.WRITE).store_string(text)

## Download material [param n], its conversion reported as [param report].
## Prints the files in its folder in the project.
func download(gallery, n: int, report: String) -> void:
    var a := asset(n)
    var staging := GalleryApi.staging_path(gallery.plugin.absolute_download_path)
    var path := GalleryApi.asset_download_dir(staging, a).path_join("rock-road_2K_6c02715d-2e81-4a9a-ae57-a961f7d3cc37.blend")
    write(path, "blend")
    await gallery.downloads.start(a, "resolution_2K")
    gallery.handle_task({"task_type": "asset_download", "task_id": "task-%d" % n, "status": "finished",
        "result": {"file_paths": [path]}})
    gallery.handle_task({"task_type": "run_blender_script", "task_id": "conv-%d" % n,
        "status": report, "message": "script produced no output"})
    await wait_until(func(): return gallery.downloads.get_download(a.assetBaseId).status == "finished", 5)
    var file: String = gallery.downloads.get_download(a.assetBaseId).file_path
    var folder := file.get_base_dir()
    print("CASE%d=%s FILES=%s DIRS=%s TEXTURES=%s LEFT=%s" % [n, file.get_file(), ",".join(DirAccess.get_files_at(folder)),
        ",".join(DirAccess.get_directories_at(folder)), ",".join(DirAccess.get_files_at(folder.path_join("textures_2K"))),
        DirAccess.dir_exists_absolute(path.get_base_dir())])
    var import := ConfigFile.new()
    if import.load(folder.path_join("textures_2K/albedo.jpg.import")) == OK:
        print("CASE%d SRC_NORMAL=%s" % [n, import.get_value("params", "roughness/src_normal")])

func check():
    var gallery = find_gallery()
    var downloads = gallery.downloads
    downloads.post_download = func(a: Dictionary, _file_type: String) -> Array:
        return ["task-%s" % a.assetBaseId.get_slice("-", 1), ""]
    downloads.post_conversion = func(plan: Dictionary) -> Array:
        print("PLAN=%s" % plan.script.get_file())
        # what's written either way, the material last
        write(plan.params.textures_dir.path_join("albedo.jpg"), "jpg")
        write(plan.params.textures_dir.path_join("albedo.jpg.import"),
            '[remap]\n\nimporter="texture"\n\n[params]\n\nroughness/mode=2\nroughness/src_normal="normal.jpg"\n')
        if mode == "convert":
            write(plan.params.output_path, '[gd_resource type="StandardMaterial3D" format=3]\n\n[resource]\n')
        return ["conv-%s" % plan.params.input_path.get_base_dir().get_file().get_slice("-", 2).left(1), ""]
    # Converted, the material moves into the project with its textures, and
    # the .blend is gone.
    await download(gallery, 1, "finished")
    # A failed conversion moves the .blend, without textures.
    mode = "fail"
    await download(gallery, 2, "error")
"""


def test_material_conversion(godot_executable, tmp_path):
    """Material .blend downloads become Godot materials with their textures."""
    project = make_probe_project(tmp_path / "project", MATERIAL_PROBE)
    stdout, stderr = run_editor_probe(godot_executable, project)
    output = stdout + stderr
    lines = stdout.splitlines()
    assert "PLAN=material_to_godot.py" in lines, output
    assert "CASE1=rock-road_2K.tres FILES=rock-road_2K.tres DIRS=textures_2K TEXTURES=albedo.jpg,albedo.jpg.import LEFT=false" in lines, output
    # The normal map path of the roughness limiter is made a project path.
    assert "CASE1 SRC_NORMAL=res://bk_assets/materials/rock-road/textures_2K/normal.jpg" in lines, output
    assert "CASE2=rock-road_2K.blend FILES=rock-road_2K.blend DIRS= TEXTURES= LEFT=false" in lines, output
    assert "Could not convert rock-road_2K_6c02715d-2e81-4a9a-ae57-a961f7d3cc37.blend for Godot" in stderr, output
    assert "SCRIPT ERROR" not in stderr, output


# Makes a material asset .blend like Blendkit's at sys.argv[-1]: its images
# packed, the roughness in the green channel, the height map a TIFF Godot
# can't import.
BUILD_MATERIAL_BLEND = r'''
import os
import sys

import bpy

out = sys.argv[-1]
images = {}
for name, ext, fmt in [("albedo", "png", "PNG"), ("orm", "png", "PNG"), ("normal", "png", "PNG"), ("height", "tif", "TIFF")]:
    image = bpy.data.images.new(name + "." + ext, 4, 4, alpha=True)
    image.pixels = [0.5] * 64
    image.filepath_raw = os.path.join(os.path.dirname(out), name + "." + ext)
    image.file_format = fmt
    image.save()
    image.pack()
    images[name] = image

mat = bpy.data.materials.new("Rock Road")
mat.use_nodes = True
mat["blenderkit"] = {"texture_size_meters": 2.0}
mat.asset_mark()
nodes, links = mat.node_tree.nodes, mat.node_tree.links
bsdf = nodes["Principled BSDF"]
bsdf.inputs["Specular IOR Level" if "Specular IOR Level" in bsdf.inputs else "Specular"].default_value = 0.25
mapping = nodes.new("ShaderNodeMapping")
mapping.inputs["Scale"].default_value = (3, 3, 3)
links.new(nodes.new("ShaderNodeTexCoord").outputs["UV"], mapping.inputs["Vector"])

def texture(name):
    node = nodes.new("ShaderNodeTexImage")
    node.image = images[name]
    links.new(mapping.outputs["Vector"], node.inputs["Vector"])
    return node

albedo = texture("albedo")
links.new(albedo.outputs["Color"], bsdf.inputs["Base Color"])
links.new(albedo.outputs["Alpha"], bsdf.inputs["Alpha"])
separate = nodes.new("ShaderNodeSeparateColor" if hasattr(bpy.types, "ShaderNodeSeparateColor") else "ShaderNodeSeparateRGB")
links.new(texture("orm").outputs["Color"], separate.inputs[0])
links.new(separate.outputs[1], bsdf.inputs["Roughness"])
normal_map = nodes.new("ShaderNodeNormalMap")
normal_map.inputs["Strength"].default_value = 0.5
links.new(texture("normal").outputs["Color"], normal_map.inputs["Color"])
links.new(normal_map.outputs["Normal"], bsdf.inputs["Normal"])
displacement = nodes.new("ShaderNodeDisplacement")
displacement.inputs["Scale"].default_value = 0.1
links.new(texture("height").outputs["Color"], displacement.inputs["Height"])
links.new(displacement.outputs["Displacement"], nodes["Material Output"].inputs["Displacement"])
mat.use_fake_user = True
bpy.ops.wm.save_as_mainfile(filepath=out)
'''


def find_blender():
    path = os.environ.get("BLENDER") or shutil.which("blender")
    if not path:
        pytest.skip("Blender not found, set BLENDER to run this test")
    return path


def run_blender(blender, script, *args):
    result = subprocess.run(
        [blender, "--background", "--factory-startup", "--python-exit-code", "1",
         "--python", str(script), "--", *map(str, args)],
        capture_output=True, text=True, timeout=120)
    assert result.returncode == 0, result.stdout + result.stderr
    return result.stdout


def test_material_script(tmp_path):
    """Blender turns a material .blend into a StandardMaterial3D."""
    blender = find_blender()
    scripts = tmp_path / "scripts"
    scripts.mkdir()
    (scripts / "build.py").write_text(BUILD_MATERIAL_BLEND)
    data = tmp_path / "data"
    data.mkdir()
    blend = data / "rock-road_2K.blend"
    run_blender(blender, scripts / "build.py", blend)
    for name in ("albedo.png", "orm.png", "normal.png", "height.tif"):
        (data / name).unlink()  # packed, so these aren't needed
    params = scripts / "params.json"
    params.write_text(json.dumps({"input_path": str(blend), "output_path": str(data / "rock-road_2K.tres"),
                                  "textures_dir": str(data / "textures_2K")}))
    run_blender(blender, ADDON_DIR / "blender" / "material_to_godot.py", params)

    tres = (data / "rock-road_2K.tres").read_text()
    lines = tres.splitlines()
    assert lines[0] == '[gd_resource type="StandardMaterial3D" format=3]', tres
    resources = {line.split(' id="')[1][:-2]: line.split('path="')[1].split('"')[0]
                 for line in lines if line.startswith("[ext_resource")}
    props = dict(line.split(" = ", 1) for line in lines[lines.index("[resource]") + 1:])
    texture = {prop: resources[value[len('ExtResource("'):-2]]
               for prop, value in props.items() if value.startswith("ExtResource")}
    assert texture == {"albedo_texture": "textures_2K/albedo.png", "roughness_texture": "textures_2K/orm.png",
                       "normal_texture": "textures_2K/normal.png", "heightmap_texture": "textures_2K/height.png"}, tres
    assert props["resource_name"] == '"Rock Road"', tres
    assert props["roughness_texture_channel"] == "1", tres  # green
    assert props["metallic_specular"] == "0.25", tres
    assert props["normal_enabled"] == "true" and props["normal_scale"] == "0.5", tres
    assert props["transparency"] == "2" and props["cull_mode"] == "2", tres  # alpha scissor, both sides
    # Godot warns of height mapping with triplanar mapping.
    assert "heightmap_enabled" not in props, tres
    # tiled 3 times per 2 m, the height in hundredths of the tile
    assert props["uv1_triplanar"] == "true" and props["uv1_scale"] == "Vector3(1.5, 1.5, 1.5)", tres
    assert float(props["heightmap_scale"]) == pytest.approx(0.1 * 3 / 2 * 100), tres
    assert "metallic_texture" not in props and "emission_enabled" not in props, tres
    # Packed images are copied as they are, the TIFF re-saved as PNG.
    textures = data / "textures_2K"
    images = ["albedo.png", "height.png", "normal.png", "orm.png"]
    assert sorted(p.name for p in textures.iterdir()) == sorted(images + [i + ".import" for i in images])
    assert (textures / "height.png").read_bytes().startswith(b"\x89PNG"), "re-saved"
    # Each is imported as Godot would reimport it on seeing it used in 3D.
    imports = {i: dict(line.split("=", 1) for line in (textures / (i + ".import")).read_text().splitlines()
                       if "=" in line) for i in images}
    for i in images:
        assert imports[i]["importer"] == '"texture"', imports[i]
        assert imports[i]["compress/mode"] == "2" and imports[i]["mipmaps/generate"] == "true", imports[i]
        assert imports[i]["detect_3d/compress_to"] == "0", imports[i]
    assert imports["normal.png"]["compress/normal_map"] == "1", imports
    assert imports["albedo.png"]["compress/normal_map"] == "2", imports
    # the roughness in green, limited by the normal map, the others not
    assert imports["orm.png"]["roughness/mode"] == "3", imports
    assert imports["orm.png"]["roughness/src_normal"] == '"normal.png"', imports
    assert {imports[i]["roughness/mode"] for i in ("albedo.png", "height.png", "normal.png")} == {"1"}, imports
