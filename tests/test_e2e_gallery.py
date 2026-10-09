"""End-to-end test of the gallery: search and download through the real Client.

The probe drives the gallery like a user would, so the requests are the
plugin's own. It needs network access to blendkit.com and is excluded from
the default run like the other e2e tests (``./dev.py test-e2e``).
"""

import re
from pathlib import Path

import pytest

from .conftest import make_probe_project, run_editor_probe

pytestmark = pytest.mark.e2e

GALLERY_PROBE = r"""
const CONNECT_S := 60.0
const SEARCH_S := 60.0
const DOWNLOAD_S := 180.0

func check():
    var gallery = find_gallery()
    var bk = gallery.plugin
    var search = gallery.search
    print("CONNECTED=%s" % await wait_until(bk.connection.is_client_connected, CONNECT_S))

    # The first search runs when the tab is first shown.
    gallery.show()
    print("DEFAULT_SEARCH=%s" % await search_done(gallery))
    print("DEFAULT_RESULTS=%d PAGES=%d" % [search.items.size(), search._page_count])

    search.free_check.button_pressed = true
    gallery.search_edit.text = "chair"
    gallery.search_edit.text_submitted.emit(gallery.search_edit.text)
    print("SEARCH=%s" % await search_done(gallery))
    print("SEARCH_MESSAGE=%s" % (search.message_label.text if search.message_box.visible else ""))
    var results: Array = search.results
    print("RESULTS=%d" % search.items.size())
    print("ALL_FREE=%s" % results.all(func(a): return a.get("isFree") == true))
    print("ALL_GLTF=%s" % results.all(func(a): return "gltf_godot" in gallery.GalleryApi.file_types(a)))
    # Thumbnails come as separate tasks.
    await wait_until(func(): return search._thumbs_missing == 0, search.THUMBS_WAIT_MS / 1000.0)
    var thumbs: int = search.items.values().filter(func(item): return item._has_thumbnail).size()
    print("THUMBNAILS=%d/%d" % [thumbs, search.items.size()])

    var downloadable := results.filter(func(a): return a.get("canDownload") == true)
    if downloadable.is_empty():
        print("NO_DOWNLOADABLE")
        return
    await download(gallery, downloadable[0])

func search_done(gallery) -> bool:
    await get_tree().process_frame
    return await wait_until(func(): return not gallery.tasks.has("search"), SEARCH_S)

## Download from the details dialog, like the Download button.
func download(gallery, asset: Dictionary):
    var Api = gallery.GalleryApi
    var base_id: String = Api.base_id(asset)
    print("ASSET=%s %s" % [asset.id, base_id])
    gallery.open_details(asset)
    print("FILE_TYPE=%s" % gallery.details.selected_file_type())
    gallery.details.confirmed.emit()
    var seen := {}
    var final := func():
        var status: String = gallery.get_download(base_id).get("status", "")
        seen[status] = true
        return not status in Api.ACTIVE_DOWNLOAD
    await wait_until(final, DOWNLOAD_S)
    var dl: Dictionary = gallery.get_download(base_id)
    print("STATUSES=%s" % [seen.keys()])
    print("STATUS=%s %s" % [dl.status, dl.message])
    print("FILE=%s" % dl.file_path)
    print("BUTTON=%s" % gallery.details.get_ok_button().text)
    print("STAGED_LEFT=%s" % FileAccess.file_exists(Api.staging_path(gallery.plugin.absolute_download_path).path_join(dl.file_path.trim_prefix(gallery.plugin.absolute_download_path))))
    gallery.details.hide()

    # The editor imports it.
    var res_path := ProjectSettings.localize_path(dl.file_path)
    var fs := EditorInterface.get_resource_filesystem()
    print("IMPORTED=%s" % await wait_until(func(): return not fs.is_scanning() and ResourceLoader.exists(res_path), 60))

    print("TILE_DOWNLOADED=%s" % gallery.search.items[base_id]._downloaded)
    gallery.project_toggle.button_pressed = true
    await get_tree().process_frame
    await get_tree().process_frame
    var tiles = gallery.project_view.entries.filter(func(e): return str(e.asset.get("id", "")) == asset.id)
    print("PROJECT_TILE=%s" % [tiles.map(func(e): return [e.known, e.asset.name == asset.name])])
    print("SAVED=%s" % await wait_until(func(): return not gallery.project_view.project.unsaved, 10))
"""


def test_gallery_search_and_download(godot_executable, tmp_path):
    project = make_probe_project(
        tmp_path / "project",
        GALLERY_PROBE,
        settings='[blendkit]\n\ndownloads/model_format="gltf_godot"\n',
        with_client=True,
    )
    stdout, stderr = run_editor_probe(godot_executable, project, timeout=400)
    output = stdout + stderr

    def value(key):
        m = re.search(rf"^{key}=(.*)$", stdout, re.M)
        assert m, f"{key} missing:\n{output}"
        return m[1]

    assert value("CONNECTED") == "true", output
    assert value("DEFAULT_SEARCH") == "true", output
    results, pages = re.fullmatch(
        r"(\d+) PAGES=(\d+)", value("DEFAULT_RESULTS")
    ).groups()
    assert int(results) > 0 and int(pages) > 1, output

    assert value("SEARCH") == "true", output
    assert value("SEARCH_MESSAGE") == "", output
    assert int(value("RESULTS")) > 0, output
    assert value("ALL_FREE") == "true", output
    assert value("ALL_GLTF") == "true", output
    got, shown = map(int, value("THUMBNAILS").split("/"))
    assert got >= shown / 2, f"most thumbnails should arrive:\n{output}"

    if "NO_DOWNLOADABLE" in stdout:
        pytest.fail(f"No downloadable free chair in the results:\n{output}")
    asset_id = value("ASSET").split()[0]
    assert value("FILE_TYPE") == "gltf_godot", output
    assert value("STATUS") == "finished ", output
    path = Path(value("FILE"))
    assert path.is_file() and path.suffix == ".glb", output
    assert path.parent.parent == project / "bk_assets" / "models", output
    assert value("STAGED_LEFT") == "false", output
    assert value("BUTTON") == "Show in FileSystem", output
    assert value("IMPORTED") == "true", output
    assert value("TILE_DOWNLOADED") == "true", output
    assert value("PROJECT_TILE") == "[[true, true]]", output
    assert value("SAVED") == "true", output
    index = (project / ".godot" / "blendkit" / "blendkit_assets.cfg").read_text()
    assert f"[{asset_id}]" in index, index
    assert "SCRIPT ERROR" not in stderr, output
