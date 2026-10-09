"""Tests for the Blendkit main-screen gallery tab."""

import os
import time

from .conftest import make_probe_project, run_editor_probe, run_godot_script


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
    result = run_godot_script(godot_executable, tmp_path, GALLERY_API_CHECKS)
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
    # A download the editor closed during, last written to an hour ago.
    stale = tmp_path / "data" / "bk_assets" / ".downloads" / "models" / "old_x"
    stale.mkdir(parents=True)
    (stale / "old.glb").write_text("partial")
    hour_ago = time.time() - 3600
    for path in (stale / "old.glb", stale):
        os.utime(path, (hour_ago, hour_ago))
    env = {"BK_TEST_DIR": str(tmp_path / "data"), "BK_STALE_DIR": str(stale)}
    result = run_godot_script(godot_executable, tmp_path, PROJECT_ASSETS_CHECKS, env)
    output = result.stdout + result.stderr
    assert result.returncode == 0, output
    assert "PROJECT_ASSETS_CHECKS_PASSED" in result.stdout, output
    assert "SCRIPT ERROR" not in result.stderr, output
    # missing type folders are skipped without engine errors
    assert "ERROR" not in result.stderr, output


MAIN_SCREEN_PROBE = r"""
const ID := "17982784-2390-4999-83d7-c72ea929f352"

func check():
    var gallery = find_gallery()
    print("GALLERY_FOUND=%s" % (gallery != null))
    if gallery:
        print("GALLERY_HIDDEN=%s" % (not gallery.visible))
        print("GALLERY_HAS_PLUGIN=%s" % (gallery.plugin != null))
        print("GALLERY_ICON=%s" % (gallery.plugin._get_plugin_icon() != null))
        await check_downloads(gallery)

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


def test_gallery_main_screen(godot_executable, tmp_path):
    """Enabling the plugin adds the gallery to the editor's main screen."""
    project = make_probe_project(tmp_path / "project", MAIN_SCREEN_PROBE)
    stdout, stderr = run_editor_probe(godot_executable, project)
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
    assert 'PROJECT_TILES=[["web-1", "Wooden Chair"]]' in stdout, output
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


RACE_PROBE = r"""
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
"""


def test_gallery_early_task_race(godot_executable, tmp_path):
    """A task reported before its POST returns goes to the request, once."""
    project = make_probe_project(tmp_path / "project", RACE_PROBE)
    stdout, stderr = run_editor_probe(godot_executable, project)
    output = stdout + stderr
    assert "POSTING=true PENDING=true" in stdout, output
    assert "EARLY_REPORTS=[] WEB_EARLY=0" in stdout, output
    assert 'RESPONSE=["race-1", ""]' in stdout, output
    # only the latest early report is replayed
    assert 'REPORTS=["finished"] POSTING=false RUNNING=false' in stdout, output
    assert 'WEB=["web-3"]' in stdout, output
    assert 'TILES=["web-3"]' in stdout, output
    assert 'SUPERSEDED=[[]] SECOND=[["race-3", ""], "finished"]' in stdout, output
    assert "DROPPED=0" in stdout, output
    assert "SCRIPT ERROR" not in stderr, output
