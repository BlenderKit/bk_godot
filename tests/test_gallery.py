"""Tests for the Blendkit main-screen gallery tab."""

import json
import os
import re
import shutil
import subprocess
import time
import urllib.request
from pathlib import Path

import pytest

from .conftest import PROJECT_DIR, unsubscribe_client

ROOT = Path(PROJECT_DIR)


def run_godot_script(godot_executable, tmp_path, project_dir, source, timeout=30):
    script = tmp_path / "checks.gd"
    script.write_text(source)
    return subprocess.run(
        [
            godot_executable,
            "--headless",
            "--log-file",
            str(tmp_path / "godot.log"),
            "--path",
            str(project_dir),
            "--script",
            str(script),
        ],
        capture_output=True,
        text=True,
        timeout=timeout,
    )


GALLERY_API_CHECKS = r"""extends SceneTree

const Api = preload("res://addons/blendkit/ui/gallery/gallery_api.gd")

var failures := 0

func check(ok: bool, what: String) -> void:
    if not ok:
        failures += 1
        print("CHECK FAILED: " + what)

func files(types: Array) -> Dictionary:
    var result := []
    for t in types:
        result.append({"fileType": t, "downloadUrl": "https://x/" + t})
    return {"assetType": "model", "files": result}

func _initialize():
    # free text is encoded per word and joined with "+", filters follow
    var url := Api.build_search_url("https://blendkit.com", "  old  chair&co ", "model", "furniture", "relevance", true, true, 3, 30, "0.6.1")
    check(url == "https://blendkit.com/api/v1/search/?query=old+chair%26co+asset_type:model+category_subtree:furniture+is_free:true+sexualizedContent:false+last_gltf_godot_upload_isnull:false+order:_score&dict_parameters=1&page_size=30&page=3&addon_version=0.6.1", url)
    # relevance without text falls back to recently updated; the root category is skipped
    url = Api.build_search_url("https://blendkit.com", "", "model", "model", "relevance", false, false, 1, 30, "0.6.1")
    check(url.contains("?query=asset_type:model+sexualizedContent:false+order:-last_blend_upload&"), url)
    # model-only filters don't apply to other types
    url = Api.build_search_url("https://blendkit.com", "wood", "material", "", "best", false, true, 1, 30, "0.6.1")
    check(url.contains("?query=wood+asset_type:material+order:-quality&"), url)
    check(Api.search_order("newest", "x") == "-created", "newest")
    check(Api.search_order("popular", "") == "-score", "popular")

    check(Api.page_count(0, 30) == 0, "no pages")
    check(Api.page_count(31, 30) == 2, "two pages")
    check(Api.page_count(3673, 30) == 123, "pages")
    check(Api.page_count(250000, 30) == 334, "clamped to the 10000 result window")

    var all := files(["blend", "gltf", "gltf_godot", "resolution_0_5K", "resolution_1K", "resolution_2K", "resolution_4K", "thumbnail"])
    check(Api.pick_file_type(all, "gltf_godot", "") == "gltf_godot", "godot glb")
    check(Api.pick_file_type(files(["blend", "gltf", "thumbnail"]), "gltf_godot", "") == "gltf", "gltf fallback")
    check(Api.pick_file_type(all, "blend", "") == "blend", "auto is original")
    check(Api.pick_file_type(all, "blend", "ORIGINAL") == "blend", "original")
    check(Api.pick_file_type(all, "blend", "resolution_2K") == "resolution_2K", "exact resolution")
    check(Api.pick_file_type(files(["blend", "resolution_1K", "resolution_4K"]), "blend", "resolution_2K") == "resolution_1K", "closest resolution")
    check(Api.pick_file_type(files(["zip_file", "thumbnail"]), "gltf_godot", "") == "zip_file", "zip")
    var material := files(["blend", "gltf", "resolution_1K"])
    material.assetType = "material"
    check(Api.pick_file_type(material, "gltf_godot", "resolution_1K") == "resolution_1K", "gltf only for models")
    check(Array(Api.downloadable_file_types(all)) == ["gltf_godot", "gltf", "blend", "resolution_4K", "resolution_2K", "resolution_1K", "resolution_0_5K"], str(Api.downloadable_file_types(all)))

    var uuid := Api.new_uuid4()
    var regex := RegEx.create_from_string("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
    check(regex.search(uuid) != null, uuid)
    check(Api.new_uuid4() != uuid, "random uuid")

    check(Api.slugify("  Ribbed Leather -- Chair!! ") == "ribbed-leather-chair", Api.slugify("  Ribbed Leather -- Chair!! "))
    var asset := {"name": "Ribbed Leather Manager Chair", "id": "2f7f-id", "assetType": "model", "assetBaseId": "base"}
    check(Api.asset_download_dir("/p/bk_assets", asset) == "/p/bk_assets/models/ribbed-leather-m_2f7f-id", Api.asset_download_dir("/p/bk_assets", asset))
    check(Api.type_download_dir("/p", "brush") == "/p/brushes", "brushes")
    check(Api.web_url("https://blendkit.com", asset) == "https://blendkit.com/asset-gallery-detail/base/", "web url")

    check(Api.task_file_path({"result": {"file_paths": ["/a.glb", "/b.glb"]}}) == "/a.glb", "file_paths")
    check(Api.task_file_path({"result": {"file_path": "/c.glb"}}) == "/c.glb", "file_path")
    check(Api.task_file_path({"result": null}) == "", "no result")

    var converted = Api.whole_floats_to_ints({"size": 51777067.0, "dim": 1.5, "files": [{"resolution": 0.0}]})
    check(JSON.stringify(converted, "", true) == '{"dim":1.5,"files":[{"resolution":0}],"size":51777067}', JSON.stringify(converted, "", true))

    check(Api.author_name({"author": {"firstName": "Ann", "lastName": "Lee"}}) == "Ann Lee", "author")
    check(Api.cant_download_message({"canDownloadError": {"messages": ["User is anonymous"]}}) == "User is anonymous", "cant download")
    check(Api.cant_download_message({"canDownloadError": true}) == "", "can download")

    # Cached avatars can be PNGs named .jpg; the format comes from the bytes.
    var img := Image.create(4, 2, false, Image.FORMAT_RGBA8)
    var mislabeled := OS.get_temp_dir().path_join("bk_test_png_as.jpg")
    img.save_png(mislabeled)
    var loaded := Api.load_image(mislabeled)
    check(loaded != null and loaded.get_size() == Vector2i(4, 2), "png named .jpg")
    DirAccess.remove_absolute(mislabeled)
    check(Api.load_image("/nonexistent.png") == null, "missing image")
    if failures == 0:
        print("GALLERY_API_CHECKS_PASSED")
    quit(failures)
"""


def test_gallery_api(godot_executable, tmp_path):
    result = run_godot_script(godot_executable, tmp_path, ROOT, GALLERY_API_CHECKS)
    output = result.stdout + result.stderr
    assert result.returncode == 0, output
    assert "GALLERY_API_CHECKS_PASSED" in result.stdout, output
    assert "SCRIPT ERROR" not in result.stderr, output


PROJECT_ASSETS_CHECKS = r"""extends SceneTree

const Api = preload("res://addons/blendkit/ui/gallery/gallery_api.gd")
const ProjectAssets = preload("res://addons/blendkit/ui/gallery/project_assets.gd")

const ID_A := "17982784-2390-4999-83d7-c72ea929f352"
const ID_B := "2f7f0000-0000-4000-8000-000000000001"

var failures := 0

func check(ok: bool, what: String) -> void:
    if not ok:
        failures += 1
        print("CHECK FAILED: " + what)

func write(path: String, text: String) -> void:
    DirAccess.make_dir_recursive_absolute(path.get_base_dir())
    FileAccess.open(path, FileAccess.WRITE).store_string(text)

func _initialize():
    var root := OS.get_environment("BK_TEST_DIR")
    var downloads := root.path_join("bk_assets")
    var index_dir := root.path_join("index")

    var url := Api.build_lookup_url("https://blendkit.com", ID_A, "0.6.1")
    check(url == "https://blendkit.com/api/v1/search/?query=asset_id:%s&dict_parameters=1&page_size=1&addon_version=0.6.1" % ID_A, url)

    check(ProjectAssets.folder_asset_id("travel-wooden-ch_" + ID_A) == ID_A, "folder id")
    check(ProjectAssets.folder_asset_id("my-folder") == "", "not an asset folder")
    check(ProjectAssets.placeholder_name("/x/travel-wooden-chess-set_gltf_godot.glb") == "Travel Wooden Chess Set", ProjectAssets.placeholder_name("/x/travel-wooden-chess-set_gltf_godot.glb"))

    # A known asset, an unknown one, and folders that aren't assets.
    var dir_a := downloads.path_join("models/travel-wooden-ch_" + ID_A)
    write(dir_a.path_join("travel-wooden-chess-set_gltf_godot.glb"), "glb")
    write(dir_a.path_join("travel-wooden-chess-set_gltf_godot.glb.import"), "import")
    var dir_b := downloads.path_join("materials/old-planks_" + ID_B)
    write(dir_b.path_join("old-planks_2K.blend"), "blend")
    DirAccess.make_dir_recursive_absolute(downloads.path_join("models/empty_" + ID_B))
    write(downloads.path_join("models/user-stuff/a.glb"), "glb")
    check(ProjectAssets.main_file(dir_a) == dir_a.path_join("travel-wooden-chess-set_gltf_godot.glb"), ProjectAssets.main_file(dir_a))

    var project := ProjectAssets.new(index_dir)
    var thumb := root.path_join("thumb.jpg")
    write(thumb, "jpg")
    project.store({"id": ID_A, "assetBaseId": "base-a", "name": "Travel wooden chess set", "assetType": "model",
        "tags": ["chess", "board"], "isFree": true, "canDownload": true}, thumb)
    check(not project.index.get_value(ID_A, "asset").has("canDownload"), "account fields dropped")
    check(FileAccess.file_exists(project.thumbnail(ID_A)), "thumbnail copied")

    check(project.get_asset(ID_A).name == "Travel wooden chess set", "indexed asset")
    check(project.get_asset(ID_B).is_empty(), "unknown asset")

    var entries := project.scan(downloads)
    check(entries.size() == 2, "two asset folders: %s" % [entries.map(func(e): return e.file_path)])

    # Downloads are staged in a hidden folder and moved when complete.
    var staging := Api.staging_path(downloads)
    check(staging == downloads.path_join(".downloads"), staging)
    Api.ensure_staging(downloads)
    check(FileAccess.get_file_as_string(staging.path_join(".gitignore")).contains("\n*\n"), "staging ignored by git")
    check(Api.unstaged_path("/p/bk_assets/.downloads/models/x/a.glb") == "/p/bk_assets/models/x/a.glb", "unstaged")
    check(Api.unstaged_path("C:\\p\\.downloads\\models\\x\\a.glb") == "C:/p/models/x/a.glb", "windows path")
    check(Api.unstaged_path("/p/bk_assets/models/x/a.glb") == "/p/bk_assets/models/x/a.glb", "not staged")
    check(project.scan(downloads).size() == 2, "staging not scanned")

    # Send to Godot downloads go to the folder changed last.
    var staged_a := staging.path_join("models/travel-wooden-ch_" + ID_A)
    write(staged_a.path_join("travel-wooden-chess-set_gltf_godot.glb"), "new glb")
    var staged_b := staging.path_join("materials/old-planks_" + ID_B)
    DirAccess.make_dir_recursive_absolute(staged_b)
    var now := int(Time.get_unix_time_from_system())
    var recent := ProjectAssets.recent_download_folder(staging, now - 60)
    check(recent.get("folder") in [staged_a, staged_b], str(recent))
    check(ProjectAssets.recent_download_folder(staging, now + 60).is_empty(), "nothing changed since")
    recent = ProjectAssets.recent_download_folder(staging, now - 60, {staged_b: true})
    check(recent == {"folder": staged_a, "id": ID_A, "asset_type": "model"}, str(recent))

    # A finished download replaces the older copy; .import stays.
    var moved := Api.finish_download(staged_a.path_join("travel-wooden-chess-set_gltf_godot.glb"))
    check(moved == dir_a.path_join("travel-wooden-chess-set_gltf_godot.glb"), moved)
    check(FileAccess.get_file_as_string(moved) == "new glb", "replaced")
    check(FileAccess.file_exists(moved + ".import"), "import kept")
    check(not DirAccess.dir_exists_absolute(staged_a), "staging folder removed")
    check(Api.finish_download(staged_a.path_join("travel-wooden-chess-set_gltf_godot.glb")) == moved, "moved twice")
    check(not FileAccess.file_exists(moved + ".bk_old"), "older copy deleted")
    check(Api.finish_download(staging.path_join("models/gone_" + ID_B + "/gone.glb")) == "", "nothing to move")
    # A new asset gets its folder.
    var staged_c := staging.path_join("models/new-one_" + ID_B)
    write(staged_c.path_join("new-one.glb"), "glb")
    moved = Api.finish_download(staged_c.path_join("new-one.glb"))
    check(moved == downloads.path_join("models/new-one_" + ID_B + "/new-one.glb") and FileAccess.file_exists(moved), moved)
    DirAccess.remove_absolute(moved)
    DirAccess.remove_absolute(moved.get_base_dir())

    # Leftovers are cleared unless kept or still written to.
    var stale := OS.get_environment("BK_STALE_DIR")
    check(DirAccess.dir_exists_absolute(stale), "stale folder prepared")
    check(Api.clear_staging(downloads, {staged_b: true}) == 1, "one stale folder")
    check(not DirAccess.dir_exists_absolute(stale), "stale folder deleted")
    check(DirAccess.dir_exists_absolute(staged_b), "kept folder")
    check(Api.clear_staging(root.path_join("nowhere"), {}) == 0, "no staging")
    var by_id := {}
    for e in entries:
        by_id[e.id] = e
    check(by_id[ID_A].known and by_id[ID_A].asset.name == "Travel wooden chess set", "known asset")
    check(not by_id[ID_B].known and by_id[ID_B].asset.name == "Old Planks" and by_id[ID_B].asset.assetType == "material", str(by_id[ID_B].asset))
    check(ProjectAssets.matches(by_id[ID_A], "CHESS board"), "matches name and tags")
    check(ProjectAssets.matches(by_id[ID_A], ""), "empty query matches")
    check(not ProjectAssets.matches(by_id[ID_A], "chess planks"), "every word must match")
    check(ProjectAssets.matches(by_id[ID_B], "planks material"), "matches placeholder and type")

    # Looked up later; the thumbnail arrives separately.
    project.store({"id": ID_B, "assetBaseId": "base-b", "name": "Old planks", "assetType": "material"})
    check(project.thumbnail(ID_B) == "", "no thumbnail yet")
    check(project.add_thumbnail("base-b", thumb) == PackedStringArray([ID_B]), "thumbnail added")
    check(project.add_thumbnail("base-b", thumb).is_empty(), "thumbnail kept")
    project.store({"id": "later-id", "assetBaseId": "base-later", "name": "Later", "assetType": "model"})
    check(project.add_thumbnail("base-later", thumb) == PackedStringArray(["later-id"]), "thumbnail of an asset stored later")
    check(project.unsaved, "changes not saved yet")
    project.save()

    # The index persists and is read back.
    var reloaded := ProjectAssets.new(index_dir)
    check(reloaded.has(ID_A) and reloaded.has(ID_B), "index saved")
    check(FileAccess.file_exists(reloaded.thumbnail(ID_B)), "thumbnail saved")
    if failures == 0:
        print("PROJECT_ASSETS_CHECKS_PASSED")
    quit(failures)
"""


def test_project_assets(godot_executable, tmp_path):
    os.environ["BK_TEST_DIR"] = str(tmp_path / "data")
    # A download the editor closed during, last written to an hour ago.
    stale = tmp_path / "data" / "bk_assets" / ".downloads" / "models" / "old_x"
    stale.mkdir(parents=True)
    (stale / "old.glb").write_text("partial")
    hour_ago = time.time() - 3600
    for path in (stale / "old.glb", stale):
        os.utime(path, (hour_ago, hour_ago))
    os.environ["BK_STALE_DIR"] = str(stale)
    try:
        result = run_godot_script(godot_executable, tmp_path, ROOT, PROJECT_ASSETS_CHECKS)
    finally:
        del os.environ["BK_TEST_DIR"]
        del os.environ["BK_STALE_DIR"]
    output = result.stdout + result.stderr
    assert result.returncode == 0, output
    assert "PROJECT_ASSETS_CHECKS_PASSED" in result.stdout, output
    assert "SCRIPT ERROR" not in result.stderr, output
    # missing type folders are skipped without engine errors
    assert "ERROR" not in result.stderr, output


MAIN_SCREEN_PROBE = r"""@tool
extends EditorPlugin

const ID := "17982784-2390-4999-83d7-c72ea929f352"

func _enter_tree():
    check.call_deferred()

func check():
    var gallery = null
    for child in EditorInterface.get_editor_main_screen().get_children():
        if child.name == "BlendkitGallery":
            gallery = child
    print("GALLERY_FOUND=%s" % (gallery != null))
    if gallery:
        print("GALLERY_HIDDEN=%s" % (not gallery.visible))
        print("GALLERY_HAS_PLUGIN=%s" % (gallery.plugin != null))
        print("GALLERY_ICON=%s" % (gallery.plugin._get_plugin_icon() != null))
        await check_downloads(gallery)
    get_tree().quit()

func check_downloads(gallery):
    var badge: Label = gallery._download_badge
    print("BADGE_HIDDEN=%s" % (not badge.visible))
    # A Send to Godot download goes to the staging folder the Client just made.
    var folder: String = gallery.plugin.absolute_download_path.path_join(".downloads/models/wooden-chair_" + ID)
    var file := folder.path_join("wooden-chair_gltf_godot.glb")
    DirAccess.make_dir_recursive_absolute(folder)
    FileAccess.open(file, FileAccess.WRITE).store_string("glb")
    # The project view only scans while the Blendkit tab shows it.
    gallery.project_toggle.button_pressed = true
    await get_tree().process_frame
    print("HIDDEN_SCANNED=%s" % (not gallery.project_view._dirty))
    gallery.show()
    await get_tree().process_frame
    print("SHOWN_SCANNED=%s" % (not gallery.project_view._dirty))
    gallery.handle_task({"task_type": "asset_download", "task_id": "web-1", "status": "created", "message": "Starting download"})
    gallery.handle_task({"task_type": "asset_download", "task_id": "web-1", "status": "progress", "progress": 40, "message": "Downloading 1.0MB (40%)"})
    print("WEB_COUNT=%d" % gallery.downloads.active_count())
    print("BADGE=%s %s" % [badge.visible, badge.text])
    print("WEB_ID=%s" % gallery.downloads.web_downloads["web-1"].id)
    # The project view refreshes once at the end of the frame.
    await get_tree().process_frame
    var entries: Array = gallery.project_view.entries
    print("PROJECT_TILES=%s" % [entries.map(func(e): return [e.id, e.asset.name])])
    var item = gallery.project_view.download_items["web-1"]
    print("TILE_TOOLTIP=%s" % item.thumb_button.tooltip_text.replace("\n", "|"))
    # Unfinished tasks are reported every poll; a missing one is gone.
    gallery.drop_vanished_downloads({"web-1": true})
    print("KEPT=%d STAGED=%s" % [gallery.downloads.active_count(), FileAccess.file_exists(file)])
    # Finished, it moves into the project.
    gallery.handle_task({"task_type": "asset_download", "task_id": "web-1", "status": "finished", "result": {"file_path": file}})
    print("FINISHED=%d BADGE_HIDDEN=%s" % [gallery.downloads.active_count(), not badge.visible])
    await get_tree().process_frame
    print("PROJECT_TILES=%s" % [gallery.project_view.entries.map(func(e): return [e.id, e.asset.name])])
    gallery.handle_task({"task_type": "asset_download", "task_id": "web-2", "status": "created"})
    await get_tree().process_frame
    print("WEB_NAME=%s" % gallery.project_view.entries[0].asset.name)
    gallery.drop_vanished_downloads({})
    print("DROPPED=%d" % gallery.downloads.active_count())
"""


def run_editor_probe(godot_executable, tmp_path, probe_source):
    """Run the editor with the plugin (without the Client) and a probe plugin.

    Returns stdout and stderr.
    """
    project = tmp_path / "project"
    shutil.copytree(
        ROOT / "addons" / "blendkit",
        project / "addons" / "blendkit",
        ignore=shutil.ignore_patterns("client"),
    )
    probe = project / "addons" / "probe"
    probe.mkdir()
    (probe / "plugin.cfg").write_text(
        '[plugin]\nname="probe"\ndescription=""\nauthor=""\nversion="0"\nscript="probe.gd"\n'
    )
    (probe / "probe.gd").write_text(probe_source)
    (project / "project.godot").write_text(
        "config_version=5\n\n[application]\n\nconfig/name=\"Gallery test\"\n\n"
        "[editor_plugins]\n\nenabled=PackedStringArray("
        '"res://addons/blendkit/plugin.cfg", "res://addons/probe/plugin.cfg")\n'
    )
    with subprocess.Popen(
        [godot_executable, "--headless", "--editor", "--path", str(project)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    ) as proc:
        try:
            stdout, stderr = proc.communicate(timeout=60)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.communicate()
            raise
    m = re.search(r"Connected to Client(?: v[\d.]+)? on port (\d+)", stdout)
    if m:
        unsubscribe_client(m.group(1), proc.pid)
    return stdout, stderr


def test_gallery_main_screen(godot_executable, tmp_path):
    """Enabling the plugin adds the gallery to the editor's main screen."""
    stdout, stderr = run_editor_probe(godot_executable, tmp_path, MAIN_SCREEN_PROBE)
    output = stdout + stderr
    assert "GALLERY_FOUND=true" in stdout, output
    assert "GALLERY_HIDDEN=true" in stdout, output
    assert "GALLERY_HAS_PLUGIN=true" in stdout, output
    assert "GALLERY_ICON=true" in stdout, output
    assert "BADGE_HIDDEN=true" in stdout, output
    assert "HIDDEN_SCANNED=false" in stdout, output
    assert "SHOWN_SCANNED=true" in stdout, output
    assert "WEB_COUNT=1" in stdout, output
    assert "BADGE=true 1" in stdout, output
    assert "WEB_ID=17982784-2390-4999-83d7-c72ea929f352" in stdout, output
    # the staged download shows only as the download
    assert "PROJECT_TILES=[[\"web-1\", \"Wooden Chair\"]]" in stdout, output
    assert "TILE_TOOLTIP=Wooden Chair|Downloading 1.0MB (40%)" in stdout, output
    assert "KEPT=1 STAGED=true" in stdout, output
    assert "FINISHED=0 BADGE_HIDDEN=true" in stdout, output
    assert "WEB_NAME=Send to Godot" in stdout, output
    assert "DROPPED=0" in stdout, output
    assert (
        'PROJECT_TILES=[["17982784-2390-4999-83d7-c72ea929f352", "Wooden Chair"]]'
        in stdout
    ), output
    assert "SCRIPT ERROR" not in stderr, output


RACE_PROBE = r"""@tool
extends EditorPlugin

func _enter_tree():
    check.call_deferred()

func find_gallery():
    for child in EditorInterface.get_editor_main_screen().get_children():
        if child.name == "BlendkitGallery":
            return child

func check():
    var gallery = find_gallery()
    var tasks = gallery.tasks
    gallery.show()
    gallery.project_toggle.button_pressed = true
    var reports := []
    var responses := []
    # A fast task is reported finished before the POST that started it returns.
    var post := func() -> Array:
        await get_tree().process_frame
        return ["race-1", ""]
    var run := func():
        responses.append(await tasks.start("race", post, func(task): reports.append(task.status)))
    run.call()
    print("POSTING=%s PENDING=%s" % [tasks.is_posting(), gallery.has_pending_work()])
    gallery.handle_task({"task_type": "asset_download", "task_id": "race-1", "status": "progress", "progress": 50})
    gallery.handle_task({"task_type": "asset_download", "task_id": "race-1", "status": "finished", "result": {}})
    # Send to Godot started meanwhile; it shows once the POST returns.
    gallery.handle_task({"task_type": "asset_download", "task_id": "web-3", "status": "created"})
    print("EARLY_REPORTS=%s WEB_EARLY=%d" % [reports, gallery.downloads.web_downloads.size()])
    while responses.is_empty():
        await get_tree().process_frame
    print("RESPONSE=%s" % [responses[0]])
    print("REPORTS=%s POSTING=%s RUNNING=%s" % [reports, tasks.is_posting(), tasks.has("race")])
    print("WEB=%s" % [gallery.downloads.web_downloads.keys()])
    await get_tree().process_frame
    print("TILES=%s" % [gallery.project_view.entries.map(func(e): return e.id)])

    # A newer request with the same key supersedes the running one.
    var superseded := []
    var slow := func() -> Array:
        await get_tree().process_frame
        return ["race-2", ""]
    var first := func():
        superseded.append(await tasks.start("race", slow, func(task): superseded.append(task.status)))
    first.call()
    var fast := func() -> Array:
        return ["race-3", ""]
    var second := func():
        responses.append(await tasks.start("race", fast, func(task): responses.append(task.status)))
    second.call()
    while superseded.is_empty():
        await get_tree().process_frame
    gallery.handle_task({"task_type": "search", "task_id": "race-2", "status": "finished"})
    gallery.handle_task({"task_type": "search", "task_id": "race-3", "status": "finished"})
    print("SUPERSEDED=%s SECOND=%s" % [superseded, responses.slice(1)])
    gallery.drop_vanished_downloads({})
    print("DROPPED=%d" % gallery.downloads.active_count())
    get_tree().quit()
"""


def test_gallery_early_task_race(godot_executable, tmp_path):
    """A task reported before its POST returns goes to the request, once."""
    stdout, stderr = run_editor_probe(godot_executable, tmp_path, RACE_PROBE)
    output = stdout + stderr
    assert "POSTING=true PENDING=true" in stdout, output
    assert 'EARLY_REPORTS=[] WEB_EARLY=0' in stdout, output
    assert 'RESPONSE=["race-1", ""]' in stdout, output
    # only the latest early report is replayed
    assert 'REPORTS=["finished"] POSTING=false RUNNING=false' in stdout, output
    assert 'WEB=["web-3"]' in stdout, output
    assert 'TILES=["web-3"]' in stdout, output
    assert 'SUPERSEDED=[[]] SECOND=[["race-3", ""], "finished"]' in stdout, output
    assert "DROPPED=0" in stdout, output
    assert "SCRIPT ERROR" not in stderr, output


# MARK: live end-to-end

SERVER = "https://blendkit.com"


def client_api_version() -> str:
    text = (ROOT / "addons" / "blendkit" / "client_binary.gd").read_text()
    return re.search(r'^const CLIENT_API_VERSION = "(v\d+\.\d+)"', text, re.M)[1]


def post(port, endpoint, body, timeout=10):
    url = f"http://127.0.0.1:{port}/{client_api_version()}/{endpoint}"
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read() or b"null")


@pytest.mark.e2e
def test_gallery_search_and_download(running_godot, tmp_path):
    """Search and download through the Client like the gallery does.

    A separate fake app_id stands in for the gallery, so the running editor's
    plugin does not consume the tasks.
    """
    port = running_godot.port
    app_id = 2_000_000_000 + os.getpid() % 1_000_000
    assets_path = tmp_path / "bk_assets"
    thumbs = tmp_path / "thumbs"
    thumbs.mkdir()
    report_body = {
        "name": "Godot",
        "appID": app_id,
        "version": "4.5.0",
        "addonVersion": "0.0.0",
        "assetsPath": str(assets_path),
        "projectName": "gallery e2e",
        "modelFormat": "gltf_godot",
        "resolution": "",
    }
    tasks = {}

    def poll_until(condition, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            for task in post(port, "godot/report", report_body).get("tasks") or []:
                tasks.setdefault(task["task_type"], {})[task["task_id"]] = task
            if condition():
                return True
            time.sleep(0.3)
        return False

    try:
        poll_until(lambda: True, 5)  # subscribe
        urlquery = (
            f"{SERVER}/api/v1/search/?query=chair+asset_type:model+is_free:true"
            "+sexualizedContent:false+last_gltf_godot_upload_isnull:false+order:_score"
            "&dict_parameters=1&page_size=5&page=1&addon_version=0.0.0"
        )
        search_id = post(
            port,
            "assets/search",
            {
                "app_id": app_id,
                "addon_version": "0.0.0",
                "platform_version": "e2e",
                "api_key": "",
                "asset_type": "model",
                "urlquery": urlquery,
                "tempdir": str(thumbs),
                "page_size": 5,
                "scene_uuid": "6f1c2a43-4b8e-4c55-9d7e-2b1f9a0c3d11",
            },
        )["task_id"]

        def search_done():
            task = tasks.get("search", {}).get(search_id)
            return task and task["status"] in ("finished", "error") and tasks.get(
                "thumbnail_download"
            )

        assert poll_until(search_done, 60), tasks.keys()
        search = tasks["search"][search_id]
        assert search["status"] == "finished", search.get("message")
        results = search["result"]["results"]
        assert results, "no search results"
        thumb = next(iter(tasks["thumbnail_download"].values()))
        assert thumb["data"]["assetBaseId"] in {a["assetBaseId"] for a in results}

        asset = next(a for a in results if a.get("canDownload"))
        download_id = post(
            port,
            "assets/download",
            {
                "app_id": app_id,
                "addon_version": "0.0.0",
                "platform_version": "e2e",
                "download_dirs": [str(assets_path / "models")],
                "resolution": "gltf_godot",
                "asset_data": {
                    "name": asset["name"],
                    "id": asset["id"],
                    "assetType": "model",
                    "files": asset["files"],
                    "available_resolutions": [],
                },
                "PREFS": {
                    "scene_id": "6f1c2a43-4b8e-4c55-9d7e-2b1f9a0c3d11",
                    "api_key": "",
                    "unpack_files": False,
                    "create_asset_library": False,
                },
            },
        )["task_id"]

        def download_done():
            task = tasks.get("asset_download", {}).get(download_id)
            return task and task["status"] in ("finished", "error")

        assert poll_until(download_done, 180), "download did not finish"
        download = tasks["asset_download"][download_id]
        assert download["status"] == "finished", download.get("message")
        path = Path(download["result"]["file_paths"][0])
        assert path.is_file()
        assert path.parent.parent == assets_path / "models"
        assert path.suffix == ".glb"
    finally:
        unsubscribe_client(port, app_id)
