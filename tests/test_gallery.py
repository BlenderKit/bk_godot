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
    var url := Api.build_search_url("https://blendkit.com", "  old  chair&co ", "model", "furniture", "relevance", true, true, 0, Api.NO_LIMIT, 3, 30, "0.6.1")
    check(url == "https://blendkit.com/api/v1/search/?query=old+chair%26co+asset_type:model+category_subtree:furniture+is_free:true+sexualizedContent:false+last_gltf_godot_upload_isnull:false+order:_score&dict_parameters=1&page_size=30&page=3&addon_version=0.6.1", url)
    # relevance without text falls back to recently updated; the root category is skipped
    url = Api.build_search_url("https://blendkit.com", "", "model", "model", "relevance", false, false, 0, Api.NO_LIMIT, 1, 30, "0.6.1")
    check(url.contains("?query=asset_type:model+sexualizedContent:false+order:-last_blend_upload&"), url)
    # model-only filters don't apply to other types
    url = Api.build_search_url("https://blendkit.com", "wood", "material", "", "best", false, true, 10, 10000, 1, 30, "0.6.1")
    check(url.contains("?query=wood+asset_type:material+order:-quality&"), url)
    # polygon counts apply to models and printables, without the open ends
    url = Api.build_search_url("https://blendkit.com", "", "printable", "", "newest", false, false, 10, 10000, 1, 30, "0.6.1")
    check(url.contains("?query=asset_type:printable+faceCount_gte:10+faceCount_lte:10000+order:-created&"), url)
    url = Api.build_search_url("https://blendkit.com", "", "model", "", "newest", false, false, 1000, Api.NO_LIMIT, 1, 30, "0.6.1")
    check(url.contains("+faceCount_gte:1000+order:") and not url.contains("faceCount_lte"), url)
    url = Api.build_search_url("https://blendkit.com", "", "model", "", "newest", false, false, 0, 10000, 1, 30, "0.6.1")
    check(url.contains("+faceCount_lte:10000+order:") and not url.contains("faceCount_gte"), url)

    check(Api.polygon_label(0, Api.NO_LIMIT) == "Any", "any")
    check(Api.polygon_label(1000, Api.NO_LIMIT) == "> 1k", "more than")
    check(Api.polygon_label(0, 10000) == "< 10k", "less than")
    check(Api.polygon_label(10, 10000) == "10 - 10k", "range")
    check(Api.polygon_label(1500, 2000000) == "1.5k - 2M", Api.polygon_label(1500, 2000000))
    check(Api.short_count(1234) == "1.234k", Api.short_count(1234))
    check(Api.short_count(950) == "950", "hundreds")
    check(Api.short_count(Api.NO_LIMIT) == "∞", "no limit")
    check(Api.parse_count(" 2.5k ") == 2500, "k")
    check(Api.parse_count("2M") == 2000000, "M")
    check(Api.parse_count("1 500") == 1500, "spaces")
    check(Api.parse_count("abc") == -1 and Api.parse_count("-5") == -1 and Api.parse_count("k") == -1, "invalid")
    check(Api.polygon_position(0) == 0.0 and Api.polygon_position(1000) == 3.0, "stops")
    check(Api.polygon_position(5) == 0.5, "linear to 10")
    check(absf(Api.polygon_position(3162) - 3.5) < 0.001, str(Api.polygon_position(3162)))
    check(Api.polygon_position(Api.NO_LIMIT) == Api.POLYGON_STOPS.size() - 1, "no limit")
    var past := Api.polygon_position(10000000)
    check(past > Api.POLYGON_STOPS.size() - 2 and past < Api.POLYGON_STOPS.size() - 1, "past the last count")
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
    check(ProjectAssets.placeholder_name("/x/travel-wooden-chess-set_gltf_godot_0e8f0b52-6a51-4c3e-9d2e-6f1d4a7c8b90.glb") == "Travel Wooden Chess Set", ProjectAssets.placeholder_name("/x/travel-wooden-chess-set_gltf_godot_0e8f0b52-6a51-4c3e-9d2e-6f1d4a7c8b90.glb"))

    # A known asset, an unknown one, and folders that aren't assets.
    var dir_a := downloads.path_join("models/travel-wooden-ch_" + ID_A)
    write(dir_a.path_join("travel-wooden-chess-set_gltf_godot_0e8f0b52-6a51-4c3e-9d2e-6f1d4a7c8b90.glb"), "glb")
    write(dir_a.path_join("travel-wooden-chess-set_gltf_godot_0e8f0b52-6a51-4c3e-9d2e-6f1d4a7c8b90.glb.import"), "import")
    # Godot extracts the textures after the .glb, so they're newer.
    write(dir_a.path_join("travel-wooden-chess-set_gltf_godot_0e8f0b52-6a51-4c3e-9d2e-6f1d4a7c8b90_Board.webp"), "webp")
    var dir_b := downloads.path_join("materials/old-planks_" + ID_B)
    write(dir_b.path_join("old-planks_2K_0e8f0b52-6a51-4c3e-9d2e-6f1d4a7c8b90.blend"), "blend")
    DirAccess.make_dir_recursive_absolute(downloads.path_join("models/empty_" + ID_B))
    write(downloads.path_join("models/user-stuff/a.glb"), "glb")
    check(ProjectAssets.main_file(dir_a) == dir_a.path_join("travel-wooden-chess-set_gltf_godot_0e8f0b52-6a51-4c3e-9d2e-6f1d4a7c8b90.glb"), ProjectAssets.main_file(dir_a))

    # Downloaded files by the Client's names, not Godot's or the user's.
    var file_id := "6c02715d-2e81-4a9a-ae57-a961f7d3cc37"
    check(ProjectAssets.download_file_type("/x/tangerines_gltf_godot_%s.glb" % file_id) == "gltf_godot", "gltf_godot")
    check(ProjectAssets.download_file_type("tangerines_gltf_%s.glb" % file_id) == "gltf", "gltf")
    check(ProjectAssets.download_file_type("tangerines_2K_%s.blend" % file_id) == "resolution_2K", "2K")
    check(ProjectAssets.download_file_type("tangerines_0_5K_%s.blend" % file_id) == "resolution_0_5K", "0.5K")
    check(ProjectAssets.download_file_type("tangerines_%s.blend" % file_id) == "blend", "original")
    check(ProjectAssets.download_file_type("tangerines_gltf_godot_%s_Naartjie.webp" % file_id) == "", "extracted texture")
    check(ProjectAssets.download_file_type("tangerines_gltf_%s.glb.import" % file_id) == "", "import file")
    check(ProjectAssets.download_file_type("tangerines_gltf.glb") == "", "no file id")
    var dir_files := downloads.path_join("models/tangerines_" + ID_B)
    write(dir_files.path_join("tangerines_gltf_godot_%s.glb" % file_id), "glb")
    write(dir_files.path_join("tangerines_gltf_godot_%s_Naartjie.webp" % file_id), "webp")
    write(dir_files.path_join("tangerines_2K_%s.blend" % file_id), "blend")
    write(dir_files.path_join("notes.txt"), "mine")
    var found := ProjectAssets.downloaded_files(dir_files)
    check(found == {"gltf_godot": dir_files.path_join("tangerines_gltf_godot_%s.glb" % file_id),
        "resolution_2K": dir_files.path_join("tangerines_2K_%s.blend" % file_id)}, str(found))
    check(ProjectAssets.downloaded_files(root.path_join("nowhere")).is_empty(), "no folder")
    for file in DirAccess.get_files_at(dir_files):
        DirAccess.remove_absolute(dir_files.path_join(file))
    DirAccess.remove_absolute(dir_files)

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
    check(entries.size() == 2, "two asset folders: %s" % [entries.map(func(e): return e.folder)])

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
    write(staged_a.path_join("travel-wooden-chess-set_gltf_godot_0e8f0b52-6a51-4c3e-9d2e-6f1d4a7c8b90.glb"), "new glb")
    var staged_b := staging.path_join("materials/old-planks_" + ID_B)
    DirAccess.make_dir_recursive_absolute(staged_b)
    var now := int(Time.get_unix_time_from_system())
    var recent := ProjectAssets.recent_download_folder(staging, now - 60)
    check(recent.get("folder") in [staged_a, staged_b], str(recent))
    check(ProjectAssets.recent_download_folder(staging, now + 60).is_empty(), "nothing changed since")
    recent = ProjectAssets.recent_download_folder(staging, now - 60, {staged_b: true})
    check(recent == {"folder": staged_a, "id": ID_A, "asset_type": "model"}, str(recent))

    # A finished download replaces the older copy; .import stays.
    var moved := Api.finish_download(staged_a.path_join("travel-wooden-chess-set_gltf_godot_0e8f0b52-6a51-4c3e-9d2e-6f1d4a7c8b90.glb"))
    check(moved == dir_a.path_join("travel-wooden-chess-set_gltf_godot_0e8f0b52-6a51-4c3e-9d2e-6f1d4a7c8b90.glb"), moved)
    check(FileAccess.get_file_as_string(moved) == "new glb", "replaced")
    check(FileAccess.file_exists(moved + ".import"), "import kept")
    check(not DirAccess.dir_exists_absolute(staged_a), "staging folder removed")
    check(Api.finish_download(staged_a.path_join("travel-wooden-chess-set_gltf_godot_0e8f0b52-6a51-4c3e-9d2e-6f1d4a7c8b90.glb")) == moved, "moved twice")
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
    check(by_id[ID_A].folder == dir_a, by_id[ID_A].folder)
    check(by_id[ID_A].files == {"gltf_godot": dir_a.path_join("travel-wooden-chess-set_gltf_godot_0e8f0b52-6a51-4c3e-9d2e-6f1d4a7c8b90.glb")}, str(by_id[ID_A].files))
    check(ProjectAssets.matches(by_id[ID_A], "gltf_godot"), "matches file names")
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
    # Godot paths use "/" on Windows too; finish_download() returns them so.
    env = {"BK_TEST_DIR": (tmp_path / "data").as_posix(), "BK_STALE_DIR": stale.as_posix()}
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
    var file := folder.path_join("wooden-chair_gltf_godot_0e8f0b52-6a51-4c3e-9d2e-6f1d4a7c8b90.glb")
    DirAccess.make_dir_recursive_absolute(folder)
    # A minimal glTF (a .glb may hold JSON), so the editor imports it cleanly.
    FileAccess.open(file, FileAccess.WRITE).store_string('{"asset": {"version": "2.0"}, "scene": 0, "scenes": [{"nodes": [0]}], "nodes": [{"name": "Chair"}]}')
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


DETAILS_PROBE = r"""
const ID := "676596bd-d7fd-47db-a9b5-a4b0e35738e7"
const FILE_ID := "b9d80621-bb1f-4335-894a-18e41438be00"

func items(details) -> Array:
    var result := []
    for i in details.file_option.item_count:
        result.append([details.file_option.get_item_metadata(i), details.file_option.get_item_icon(i) != null])
    return result

func check():
    var gallery = find_gallery()
    var details = gallery.details
    # Outside the project, so the editor doesn't import the fake files.
    var folder := OS.get_user_data_dir().path_join("bk_details_test/tangerines_" + ID)
    DirAccess.make_dir_recursive_absolute(folder)
    for file in ["tangerines_gltf_godot_%s.glb" % FILE_ID, "tangerines_gltf_godot_%s_Naartjie.webp" % FILE_ID,
            "tangerines_2K_%s.blend" % FILE_ID, "notes.txt"]:
        FileAccess.open(folder.path_join(file), FileAccess.WRITE).store_string("x")
    # From the project assets: the index entry has no files to download.
    var asset := {"id": ID, "assetBaseId": "base", "name": "Tangerines", "assetType": "model"}
    details.show_asset(asset, {}, folder)
    print("ITEMS=%s" % [items(details)])
    print("SELECTED=%s BUTTON=%s" % [details.selected_file_type(), details.action_button.text])
    print("NOTE=%s" % details.note_label.text)
    print("TOOLTIP=%s" % details.action_button.tooltip_text)
    details.file_option.select(1)
    details.file_option.item_selected.emit(1)
    print("SELECTED=%s BUTTON=%s" % [details.selected_file_type(), details.action_button.text])
    # Looked up, the other files can be downloaded too.
    var full := asset.duplicate()
    full.canDownload = true
    full.files = ["gltf", "gltf_godot", "blend", "resolution_2K", "resolution_1K"].map(func(t): return {"fileType": t})
    details.update_asset(full)
    print("ITEMS=%s" % [items(details)])
    print("SELECTED=%s" % details.selected_file_type())
    details.file_option.select(0)
    details.file_option.item_selected.emit(0)
    print("SELECTED=%s BUTTON=%s" % [details.selected_file_type(), details.action_button.text])
    # From the search, the files are in the folder it downloads to.
    details.show_asset(full, {})
    print("SEARCH_FOLDER=%s" % (details.folder == gallery.plugin.absolute_download_path.path_join("models/tangerines_" + ID)))
    print("SEARCH_SELECTED=%s BUTTON=%s" % [details.selected_file_type(), details.action_button.text])
    details.hide()
"""


def test_gallery_details_files(godot_executable, tmp_path):
    """The details list the downloaded files, marked, and show them."""
    project = make_probe_project(
        tmp_path / "project",
        DETAILS_PROBE,
        settings='[blendkit]\n\ndownloads/model_format="gltf_godot"\n',
    )
    stdout, stderr = run_editor_probe(godot_executable, project)
    output = stdout + stderr
    lines = [line for line in stdout.splitlines() if "=" in line]
    # Only the Client's files: no extracted texture, no user file.
    assert 'ITEMS=[["gltf_godot", true], ["resolution_2K", true]]' in lines, output
    assert "SELECTED=gltf_godot BUTTON=Show File" in lines, output
    assert "NOTE=tangerines_gltf_godot_b9d80621-bb1f-4335-894a-18e41438be00.glb" in lines, output
    assert (
        "TOOLTIP=Show the file in the FileSystem dock if Godot imports it, otherwise in the file manager."
    ) in lines, output
    assert "SELECTED=resolution_2K BUTTON=Show File" in lines, output
    assert (
        'ITEMS=[["gltf_godot", true], ["gltf", false], ["blend", false], '
        '["resolution_2K", true], ["resolution_1K", false]]'
    ) in lines, output
    # the lookup keeps the selection
    assert "SELECTED=resolution_2K" in lines, output
    assert "SELECTED=gltf_godot BUTTON=Show File" in lines, output
    assert "SEARCH_FOLDER=true" in lines, output
    assert "SEARCH_SELECTED=gltf_godot BUTTON=Download" in lines, output
    assert "SCRIPT ERROR" not in stderr, output


FILE_POINTER_PROBE = r"""
const FileReveal = preload("res://addons/blendkit/ui/file_reveal.gd")
const FilePointer = preload("res://addons/blendkit/ui/file_pointer.gd")

func pointer():
    for child in get_window().get_children():
        if child.get_script() == FilePointer:
            return child

## Where the pointer lands, once it found the file, and whether that is on
## [param widget].
func landing(widget: Control) -> String:
    for i in 6:
        await get_tree().process_frame
    var p = pointer()
    if p == null:
        return "none"
    return str(widget.get_global_rect().has_point(p.get_global_position() + p._target))

func check():
    # Indexed at startup, so reveal() doesn't fall back to the file manager.
    var path := "res://assets/pointer/model.tres"
    var dock := EditorInterface.get_file_system_dock()
    var tree: Tree = dock.find_children("*", "Tree", true, false)[0]
    var list: ItemList = dock.find_children("*", "ItemList", true, false)[0]
    FileReveal.reveal(path)
    await wait_until(func(): return pointer() != null, 10.0)
    print("TREE_LANDED=%s" % await landing(tree))
    print("TREE_FREED=%s" % await wait_until(func(): return pointer() == null, 5.0))
    # The split view selects the file in the file list.
    for button: Button in dock.find_children("*", "Button", true, false):
        if button.tooltip_text == "Change Split Mode":
            button.pressed.emit()
    FileReveal.reveal(path)
    print("LIST_LANDED=%s" % await landing(list))
    await wait_until(func(): return pointer() == null, 5.0)
    # A file the dock didn't select: no pointer, no errors.
    FilePointer.point_at("res://assets/pointer/missing.tres")
    print("MISSING=%s" % await landing(list))
"""


def test_file_pointer(godot_executable, tmp_path):
    """Show File points at the file in the FileSystem dock, in either layout."""
    project = make_probe_project(tmp_path / "project", FILE_POINTER_PROBE)
    (project / "assets" / "pointer").mkdir(parents=True)
    (project / "assets" / "pointer" / "model.tres").write_text(
        '[gd_resource type="Resource" format=3]\n\n[resource]\n'
    )
    stdout, stderr = run_editor_probe(godot_executable, project)
    output = stdout + stderr
    lines = stdout.splitlines()
    assert "TREE_LANDED=true" in lines, output
    assert "TREE_FREED=true" in lines, output
    assert "LIST_LANDED=true" in lines, output
    assert "MISSING=none" in lines, output
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


STALE_FILE_PROBE = r"""
const ID := "676596bd-d7fd-47db-a9b5-a4b0e35738e7"
const NOT_FOUND := 'server returned non-OK status (404): {"detail":"No AssetFile matches the given query.","statusCode":404}'

func asset(id: String, url: String) -> Dictionary:
    return {"id": id, "assetBaseId": "base", "name": "Tangerines", "assetType": "model", "canDownload": true,
        "files": [{"fileType": "gltf_godot", "downloadUrl": url}]}

func lookup(task_id: String, found: Dictionary) -> void:
    find_gallery().handle_task({"task_type": "search", "task_id": task_id, "status": "finished",
        "result": {"results": [found]}})

func fail(task_id: String) -> void:
    find_gallery().handle_task({"task_type": "asset_download", "task_id": task_id, "status": "error", "message": NOT_FOUND})

func state(gallery) -> String:
    var dl: Dictionary = gallery.downloads.get_download("base")
    return "%s|%s" % [dl.status, dl.message]

func check():
    var gallery = find_gallery()
    var downloads = gallery.downloads
    var posts := []
    downloads.post_download = func(a: Dictionary, file_type: String) -> Array:
        posts.append(["download", a.files[0].downloadUrl, file_type])
        return ["task-%d" % posts.size(), ""]
    downloads.post_lookup = func(a: Dictionary) -> Array:
        posts.append(["lookup", a.id])
        return ["task-%d" % posts.size(), ""]
    var stale := asset(ID, "old")
    gallery.search.results = [stale]
    gallery.details.show_asset(stale, {})
    await downloads.start(stale, "gltf_godot")
    print("STARTED=%s" % state(gallery))
    # The file is gone: look the asset up once and download its new file.
    fail("task-1")
    print("REFRESHING=%s ACTIVE=%d" % [state(gallery), downloads.active_count()])
    lookup("task-2", asset(ID, "new"))
    print("POSTS=%s" % [posts])
    print("RETRIED=%s" % state(gallery))
    print("RESULTS=%s" % gallery.search.results[0].files[0].downloadUrl)
    print("DETAILS=%s" % gallery.details.asset.files[0].downloadUrl)
    # Gone again, it gives up.
    fail("task-3")
    print("GAVE_UP=%s POSTS=%d" % [state(gallery), posts.size()])
    # A lookup that finds another asset doesn't retry.
    posts.clear()
    await downloads.start(stale, "gltf_godot")
    fail("task-1")
    lookup("task-2", asset("other", "new"))
    print("OTHER=%s POSTS=%s" % [state(gallery), posts])
    gallery.details.hide()
"""


def test_gallery_stale_file_retry(godot_executable, tmp_path):
    """A download whose file was regenerated on the server looks the asset
    up and retries once with its new files."""
    project = make_probe_project(tmp_path / "project", STALE_FILE_PROBE)
    stdout, stderr = run_editor_probe(godot_executable, project)
    output = stdout + stderr
    lines = stdout.splitlines()
    stale = "The asset's files changed on Blendkit. Search again to download it."
    assert "STARTED=created|Starting download" in lines, output
    assert "REFRESHING=refreshing|Refreshing asset data ACTIVE=1" in lines, output
    assert (
        'POSTS=[["download", "old", "gltf_godot"], '
        '["lookup", "676596bd-d7fd-47db-a9b5-a4b0e35738e7"], '
        '["download", "new", "gltf_godot"]]'
    ) in lines, output
    assert "RETRIED=created|Starting download" in lines, output
    assert "RESULTS=new" in lines, output
    assert "DETAILS=new" in lines, output
    assert f"GAVE_UP=error|{stale} POSTS=3" in lines, output
    assert (
        f'OTHER=error|{stale} POSTS=[["download", "old", "gltf_godot"], '
        '["lookup", "676596bd-d7fd-47db-a9b5-a4b0e35738e7"]]'
    ) in lines, output
    assert "SCRIPT ERROR" not in stderr, output


POLYGONS_PROBE = r"""
const GalleryApi = preload("res://addons/blendkit/ui/gallery/gallery_api.gd")

func press(slider, x: float, pressed: bool) -> void:
    var event := InputEventMouseButton.new()
    event.button_index = MOUSE_BUTTON_LEFT
    event.pressed = pressed
    event.position = Vector2(x, 5)
    slider._gui_input(event)

func move(slider, x: float, pressed: bool = true) -> void:
    var event := InputEventMouseMotion.new()
    event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
    event.position = Vector2(x, 5)
    slider._gui_input(event)

func check():
    var gallery = find_gallery()
    var search = gallery.search
    var polygons = search.polygon_filter
    var row: Control = polygons.get_parent()
    print("LABEL=%s" % polygons.text)
    search.type_option.select(GalleryApi.ASSET_TYPES.find("printable"))
    search._on_type_selected(search.type_option.selected)
    print("PRINTABLE_SHOWN=%s" % row.visible)
    search.type_option.select(GalleryApi.ASSET_TYPES.find("scene"))
    search._on_type_selected(search.type_option.selected)
    print("SCENE_SHOWN=%s" % row.visible)
    search.type_option.select(GalleryApi.ASSET_TYPES.find("model"))
    search._on_type_selected(search.type_option.selected)
    print("MODEL_SHOWN=%s" % row.visible)
    var slider = polygons._slider
    slider.size = Vector2(400, 40)
    var changes := []
    polygons.range_changed.connect(func(): changes.append(polygons.text))
    # Drag the low grabber from 0 to the 10 stop; a click on the track moves
    # the nearest grabber there, then it drags to 10k.
    press(slider, slider._x(0), true)
    move(slider, slider._x(1))
    press(slider, slider._x(1), false)
    press(slider, slider._x(6), true)
    move(slider, slider._x(4))
    press(slider, slider._x(4), false)
    print("DRAGGED=%s" % [changes])
    print("SAVED=%s" % [search._get_meta("gallery_polygons", [])])
    # Dragged past the low grabber, the high one pushes it along.
    press(slider, slider._x(4), true)
    move(slider, slider._x(0))
    press(slider, slider._x(0), false)
    print("CLAMPED=%s %s" % [polygons.min_faces, polygons.max_faces])
    # Released outside the popup, the next motion without the button stops
    # the drag.
    press(slider, slider._x(1), true)
    move(slider, slider._x(5), false)
    move(slider, slider._x(5))
    print("RELEASED_OUTSIDE=%s %s" % [polygons.max_faces, slider._dragging])
    polygons._min_edit.text = "2.5k"
    polygons._max_edit.text = ""
    polygons._apply_edits()
    print("TYPED=%s" % polygons.text)
    polygons._min_edit.text = "lots"
    polygons._apply_edits()
    print("INVALID=%s %s" % [polygons.text, polygons._min_edit.text])
    var url := GalleryApi.build_search_url("", "", "model", "", "newest", false, false,
        polygons.min_faces, polygons.max_faces, 1, 30, "")
    print("URL_GTE=%s" % url.contains("faceCount_gte:2500+"))
    print("ANY_ENABLED=%s" % (not polygons._any_button.disabled))
    polygons._any_button.pressed.emit()
    print("CLEARED=%s %s" % [polygons.text, polygons._any_button.disabled])
"""


def test_gallery_polygons(godot_executable, tmp_path):
    """The Polygons filter shows for models and printables and edits a range."""
    project = make_probe_project(tmp_path / "project", POLYGONS_PROBE)
    stdout, stderr = run_editor_probe(godot_executable, project)
    output = stdout + stderr
    lines = stdout.splitlines()
    assert "LABEL=Any" in lines, output
    assert "PRINTABLE_SHOWN=true" in lines, output
    assert "SCENE_SHOWN=false" in lines, output
    assert "MODEL_SHOWN=true" in lines, output
    assert 'DRAGGED=["> 10", "10 - 1M", "10 - 10k"]' in lines, output
    assert "SAVED=[10, 10000]" in lines, output
    assert "CLAMPED=0 10" in lines, output
    assert "RELEASED_OUTSIDE=10 -1" in lines, output
    assert "TYPED=> 2.5k" in lines, output
    assert "INVALID=> 2.5k 2.5k" in lines, output
    assert "URL_GTE=true" in lines, output
    assert "ANY_ENABLED=true" in lines, output
    assert "CLEARED=Any true" in lines, output
    assert "SCRIPT ERROR" not in stderr, output
