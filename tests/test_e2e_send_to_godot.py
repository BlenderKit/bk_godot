"""End-to-end test of the full 'Send to Godot' chain.

This drives the real flow described in the README:

    Godot (plugin) -> spawns + subscribes to Blendkit Client
    Browser on blenderkit.com -> 'Send to Godot' button -> Client get_asset
    Client downloads the asset -> file lands in bk_assets/
    Gallery shows the download -> looks the asset up on Blendkit

It is a live integration test: it needs network access to blenderkit.com and a
real browser. It is excluded from the default test run (see pytest.ini -> addopts
``-m "not e2e"``); run it explicitly with ``./dev.py test-e2e`` or ``pytest -m e2e``.

Environment variables:
    BLENDERKIT_API_KEY  Optional. Injected like a logged-in page so the download
                        request carries it (required only for gated assets).
    HEADED=1            Optional. Run the browser visibly instead of headless.
"""

import json
import os
import re
from pathlib import Path

import pytest

from .conftest import (
    CLIENT_CONNECTED_RE,
    GodotEditor,
    make_probe_project,
)

# Playwright is a dev-only extra; skip this whole module if it isn't installed.
sync_api = pytest.importorskip("playwright.sync_api")
sync_playwright = sync_api.sync_playwright


# The page hosting the "Send to Godot" button (the dedicated get-blenderkit page,
# where client-buttons.js lives). Override via env to point at staging or a
# different asset.
SITE = os.environ.get("BLENDERKIT_E2E_SITE", "https://www.blenderkit.com")
ASSET_BASE_ID = os.environ.get(
    "BLENDERKIT_E2E_ASSET", "ea0e17ae-f7c7-4768-bd6c-1255c67b17c6"
)
ASSET_URL = f"{SITE}/get-blendkit/{ASSET_BASE_ID}/"

# An HTTPS page (blenderkit.com) fetching the Client on http://127.0.0.1 is the
# documented Browser<->Client "weak point": it trips browser mixed-content and
# local-network policy. Newer Chromium gates this behind a Local Network Access
# (LNA) permission prompt ("Access other apps and services"); older versions use
# Private Network Access (PNA). Playwright can't auto-grant LNA (it's not in
# grant_permissions()), so we disable the checks via launch flags for this
# throwaway test browser, which suppresses the prompt and lets bkclientjs reach
# the Client so the button(s) render.
CHROMIUM_ARGS = [
    "--allow-running-insecure-content",
    "--disable-features="
    "LocalNetworkAccessChecks,"  # Chrome 138+ "Access other apps and services"
    "LocalNetworkAccess,"  # alternate name across builds (ignored if unknown)
    "BlockInsecurePrivateNetworkRequests,"
    "PrivateNetworkAccessSendPreflights,"
    "PrivateNetworkAccessRespectPreflightResults",
]

BUTTON_TIMEOUT_MS = 60_000  # button appears after a bkclientjs poll (5s interval)
GET_ASSET_TIMEOUT_MS = 30_000
DOWNLOAD_TIMEOUT_S = 180  # Client downloads the asset bytes from the CDN
FAILURE_SCREENSHOT = os.path.join(os.path.dirname(__file__), "e2e_failure.png")


def _is_local(url: str) -> bool:
    return "127.0.0.1" in url or "localhost" in url


def _dismiss_cookie_banner(page) -> None:
    """Accept the Cookiebot consent banner if present.

    blenderkit.com loads Cookiebot (consent.cookiebot.com/uc.js) with
    data-blockingmode="auto", so the banner both overlays the page (intercepting
    clicks) and can defer scripts until consent. Accepting all clears both.
    The banner may be absent (already consented, or a region without it), so this
    is best-effort and never fails the test on its own.
    """
    dialog = page.locator("#CybotCookiebotDialog")
    try:
        dialog.wait_for(state="visible", timeout=8_000)
    except sync_api.TimeoutError:
        return  # no banner (already consented, or site without Cookiebot)

    # Stable Cookiebot button IDs, in order of preference.
    for selector in (
        "#CybotCookiebotDialogBodyLevelButtonLevelOptinAllowAll",
        "#CybotCookiebotDialogBodyButtonAccept",
        "#CybotCookiebotDialogBodyButtonDecline",
    ):
        button = page.locator(selector)
        if button.count() and button.is_visible():
            button.click()
            # Wait for the dialog to go away so it can't intercept later clicks.
            dialog.wait_for(state="hidden", timeout=5_000)
            return


def _assert_expected_asset_page(page, response) -> None:
    """Fail early when navigation did not reach the requested asset page."""
    asset_marker = page.locator("#asset-base-id").first
    actual_asset_id = (
        asset_marker.get_attribute("data-asset-base-id")
        if asset_marker.count()
        else None
    )
    if actual_asset_id == ASSET_BASE_ID:
        return

    headers = response.headers if response is not None else {}
    body_text = " ".join(page.locator("body").inner_text().split())
    body_excerpt = body_text[:500]
    challenge_text = body_text.lower()
    cloudflare_challenge = (
        headers.get("cf-mitigated", "").lower() == "challenge"
        or "performing security verification" in challenge_text
        or "verify you are human" in challenge_text
    )
    page.screenshot(path=FAILURE_SCREENSHOT, full_page=True)
    diagnostics = (
        f"Navigation: HTTP {response.status if response is not None else 'unknown'} "
        f"-> {page.url}\n"
        f"Title: {page.title()!r}\n"
        f"Cloudflare: cf-mitigated={headers.get('cf-mitigated')!r}, "
        f"cf-ray={headers.get('cf-ray')!r}\n"
        f"Expected #asset-base-id={ASSET_BASE_ID!r}; got {actual_asset_id!r}\n"
        f"Body excerpt: {body_excerpt!r}\n"
        f"Screenshot: {FAILURE_SCREENSHOT}"
    )
    if cloudflare_challenge:
        pytest.skip(
            "Cloudflare served a bot challenge instead of the asset page.\n"
            f"{diagnostics}"
        )

    pytest.fail(
        f"The response was not the expected Blendkit asset page.\n{diagnostics}",
        pytrace=False,
    )


# Watches the gallery while the browser sends the asset.
WEB_PROBE = r"""
const LOOKUP_S := 60.0

func check():
    var gallery = find_gallery()
    var downloads = gallery.downloads
    await wait_until(gallery.plugin.connection.is_client_connected, 60)
    # Shown, the project view looks up the downloaded asset.
    gallery.show()
    gallery.project_toggle.button_pressed = true
    var finished := []
    downloads.web_download_finished.connect(func(path): finished.append(path))
    var seen := {"badge": 0, "tiles": {}}
    var watch := func():
        if gallery._download_badge.visible:
            seen.badge = maxi(seen.badge, int(gallery._download_badge.text))
        for id in gallery.project_view.download_items:
            seen.tiles[id] = true
        return not finished.is_empty()
    print("WEB_FINISHED=%s" % await wait_until(watch, float(OS.get_environment("BK_E2E_DOWNLOAD_S"))))
    print("BADGE_MAX=%d" % seen.badge)
    print("BADGE_HIDDEN=%s" % (not gallery._download_badge.visible))
    print("DOWNLOAD_TILES=%d" % seen.tiles.size())
    print("FILE=%s" % (finished[0] if finished else ""))

    var base_id := OS.get_environment("BK_E2E_ASSET_BASE_ID")
    var project = gallery.project_view
    var looked_up := func():
        return project.entries.any(func(e): return e.known and e.asset.get("assetBaseId") == base_id)
    print("LOOKED_UP=%s" % await wait_until(looked_up, LOOKUP_S))
    for e in project.entries:
        if e.asset.get("assetBaseId") == base_id:
            print("PROJECT_TILE=%s|%s|%s" % [e.asset.name, e.has("download"), not project.project.thumbnail(e.id).is_empty()])
    print("SAVED=%s" % await wait_until(func(): return not project.project.unsaved, 10))
"""


@pytest.mark.e2e
def test_send_to_godot_downloads_asset(godot_executable, tmp_path):
    project = make_probe_project(tmp_path / "project", WEB_PROBE, with_client=True)
    with GodotEditor(
        godot_executable,
        project,
        env={
            "BK_E2E_ASSET_BASE_ID": ASSET_BASE_ID,
            "BK_E2E_DOWNLOAD_S": str(DOWNLOAD_TIMEOUT_S),
        },
    ) as editor:
        editor.wait_for(CLIENT_CONNECTED_RE.pattern, 60)
        _send_from_browser(editor.process.pid)
        editor.wait(DOWNLOAD_TIMEOUT_S + 120)
    stdout, output = editor.stdout, editor.output

    def value(key):
        m = re.search(rf"^{key}=(.*)$", stdout, re.M)
        assert m, f"{key} missing:\n{output}"
        return m[1]

    # The Client downloads asynchronously, and the plugin moves the file
    # into bk_assets/ once complete.
    assert value("WEB_FINISHED") == "true", (
        f"No Send to Godot download finished within {DOWNLOAD_TIMEOUT_S}s.\n{output}"
    )
    path = Path(value("FILE"))
    assert path.is_file() and path.stat().st_size > 0, output
    assert project / "bk_assets" in path.parents, output
    assert ".downloads" not in path.parts, output
    # The badge counted the download, if it ran long enough to be reported.
    assert int(value("BADGE_MAX")) <= 1 and int(value("DOWNLOAD_TILES")) <= 1, output
    assert value("BADGE_HIDDEN") == "true", output
    # The project view found the asset on Blendkit: its name, not a guess.
    assert value("LOOKED_UP") == "true", output
    name, is_download, thumbnail = value("PROJECT_TILE").split("|")
    assert name and name != "Send to Godot", output
    assert is_download == "false" and thumbnail == "true", output
    assert value("SAVED") == "true", output
    assert "SCRIPT ERROR" not in editor.stderr, output


def _send_from_browser(app_id: int) -> None:
    """Press Send to Godot on the asset page; fails unless the Client accepts it.

    Each subscribed Godot gets a button, and nothing tells them apart, so the
    request is sent to the test editor ([param app_id]) whichever is pressed.
    A developer's own editors don't get the asset then.
    """
    api_key = os.environ.get("BLENDERKIT_API_KEY", "")
    headed = os.environ.get("HEADED") == "1"

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=not headed, args=CHROMIUM_ARGS)
        page = browser.new_context().new_page()

        # Diagnostics: the Browser<->Client hop is the fragile part, so capture
        # console output and any traffic to the local Client to explain failures.
        console_msgs: list = []
        page.on("console", lambda m: console_msgs.append(f"[{m.type}] {m.text}"))
        local_net: list = []
        page.on(
            "requestfailed",
            lambda r: (
                _is_local(r.url)
                and local_net.append(f"FAILED {r.method} {r.url} :: {r.failure}")
            ),
        )
        page.on(
            "response",
            lambda r: (
                _is_local(r.url)
                and local_net.append(f"{r.status} {r.request.method} {r.url}")
            ),
        )

        def to_test_editor(route):
            if route.request.method != "POST":
                route.continue_()
                return
            body = json.loads(route.request.post_data or "{}")
            body["app_id"] = app_id
            route.continue_(post_data=json.dumps(body))

        page.route("**/bkclientjs/get_asset", to_test_editor)

        response = page.goto(ASSET_URL, wait_until="domcontentloaded")
        _assert_expected_asset_page(page, response)
        _dismiss_cookie_banner(page)

        # Expose the API key the way a logged-in page would, so the button's
        # get_asset call carries it (needed only for gated assets).
        if api_key:
            page.evaluate(
                """(key) => {
                    let el = document.getElementById('api-key');
                    if (!el) {
                        el = document.createElement('div');
                        el.id = 'api-key';
                        document.body.appendChild(el);
                    }
                    el.setAttribute('data-api-key', key);
                }""",
                api_key,
            )

        # The button is rendered by client-buttons.js once bkclientjs detects
        # our running Godot on the Client; text is "Send to Godot (vX.Y.Z)".
        button = page.get_by_role(
            "button", name=re.compile("Send to Godot", re.I)
        ).first
        try:
            button.wait_for(state="visible", timeout=BUTTON_TIMEOUT_MS)
        except sync_api.TimeoutError:
            page.screenshot(path=FAILURE_SCREENSHOT, full_page=True)
            pytest.fail(
                "'Send to Godot' button never appeared - bkclientjs likely "
                "could not reach the local Client.\n"
                f"Screenshot: {FAILURE_SCREENSHOT}\n"
                f"Local Client traffic ({len(local_net)} events):\n  "
                + (
                    "\n  ".join(local_net)
                    or "(none - the browser made no request to the Client at all)"
                )
                + "\nConsole (bkclientjs/widget/security):\n  "
                + "\n  ".join(
                    m
                    for m in console_msgs
                    if re.search(
                        r"client|software|widget|insecure|mixed|private|cors|blocked",
                        m,
                        re.I,
                    )
                )
            )

        def is_get_asset_post(resp):
            return "/bkclientjs/get_asset" in resp.url and resp.request.method == "POST"

        with page.expect_response(
            is_get_asset_post, timeout=GET_ASSET_TIMEOUT_MS
        ) as resp_info:
            button.click()

        status = resp_info.value.status
        assert status == 200, f"Client get_asset returned HTTP {status}"
        # (The button's transient "Sent successfully!" state isn't asserted:
        # it shows for only ~3s and the 5s discovery poll rebuilds the buttons.
        # The 200 above plus the downloaded file below are the real signals.)
        browser.close()
