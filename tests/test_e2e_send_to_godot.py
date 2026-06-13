"""End-to-end test of the full 'Send to Godot' chain.

This drives the real flow described in the README:

    Godot (plugin) -> spawns + subscribes to Blendkit Client
    Browser on blenderkit.com -> 'Send to Godot' button -> Client get_asset
    Client downloads the asset -> file lands in bk_assets/

It is a live integration test: it needs network access to blenderkit.com and a
real browser. It is excluded from the default test run (see pytest.ini -> addopts
``-m "not e2e"``); run it explicitly with ``./dev.py test-e2e`` or ``pytest -m e2e``.

Environment variables:
    BLENDERKIT_API_KEY  Optional. Injected like a logged-in page so the download
                        request carries it (required only for gated assets).
    HEADED=1            Optional. Run the browser visibly instead of headless.
"""

import os
import time

import pytest

# Playwright is a dev-only extra; skip this whole module if it isn't installed.
sync_api = pytest.importorskip("playwright.sync_api")
sync_playwright = sync_api.sync_playwright

import re  # noqa: E402  (after importorskip so a missing Playwright skips cleanly)


# The page hosting the "Send to Godot" button (the dedicated get-blenderkit page,
# where client-buttons.js lives). Override via env to point at staging or a
# different asset.
SITE = os.environ.get("BLENDERKIT_E2E_SITE", "https://www.blenderkit.com")
ASSET_BASE_ID = os.environ.get(
    "BLENDERKIT_E2E_ASSET", "ea0e17ae-f7c7-4768-bd6c-1255c67b17c6"
)
ASSET_URL = f"{SITE}/get-blenderkit/{ASSET_BASE_ID}/"

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
    "LocalNetworkAccess,"        # alternate name across builds (ignored if unknown)
    "BlockInsecurePrivateNetworkRequests,"
    "PrivateNetworkAccessSendPreflights,"
    "PrivateNetworkAccessRespectPreflightResults",
]

BUTTON_TIMEOUT_MS = 60_000   # button appears after a bkclientjs poll (5s interval)
GET_ASSET_TIMEOUT_MS = 30_000
DOWNLOAD_TIMEOUT_S = 180      # Client downloads the asset bytes from the CDN


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


def _all_files(root: str) -> set:
    return {
        os.path.join(dirpath, name)
        for dirpath, _dirs, names in os.walk(root)
        for name in names
    }


@pytest.fixture
def assets_dir() -> str:
    """The plugin's default download directory (res://bk_assets/)."""
    return os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "bk_assets"
    )


@pytest.mark.e2e
def test_send_to_godot_downloads_asset(running_godot, assets_dir):
    before = _all_files(assets_dir)
    api_key = os.environ.get("BLENDERKIT_API_KEY", "")
    headed = os.environ.get("HEADED") == "1"

    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(headless=not headed, args=CHROMIUM_ARGS)
            page = browser.new_context().new_page()

            # Diagnostics: the Browser<->Client hop is the fragile part, so capture
            # console output and any traffic to the local Client to explain failures.
            console_msgs: list = []
            page.on(
                "console", lambda m: console_msgs.append(f"[{m.type}] {m.text}")
            )
            local_net: list = []
            page.on(
                "requestfailed",
                lambda r: _is_local(r.url)
                and local_net.append(f"FAILED {r.method} {r.url} :: {r.failure}"),
            )
            page.on(
                "response",
                lambda r: _is_local(r.url)
                and local_net.append(f"{r.status} {r.request.method} {r.url}"),
            )

            page.goto(ASSET_URL, wait_until="domcontentloaded")
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
            button = page.get_by_role("button", name=re.compile("Send to Godot", re.I))
            try:
                button.wait_for(state="visible", timeout=BUTTON_TIMEOUT_MS)
            except sync_api.TimeoutError:
                shot = os.path.join(os.path.dirname(__file__), "e2e_failure.png")
                page.screenshot(path=shot, full_page=True)
                pytest.fail(
                    "'Send to Godot' button never appeared - bkclientjs likely "
                    "could not reach the local Client.\n"
                    f"Screenshot: {shot}\n"
                    f"Local Client traffic ({len(local_net)} events):\n  "
                    + ("\n  ".join(local_net) or "(none - the browser made no "
                       "request to the Client at all)")
                    + "\nConsole (bkclientjs/widget/security):\n  "
                    + "\n  ".join(
                        m for m in console_msgs
                        if re.search(
                            r"client|software|widget|insecure|mixed|private|cors|blocked",
                            m, re.I,
                        )
                    )
                )

            def is_get_asset_post(resp):
                return (
                    "/bkclientjs/get_asset" in resp.url
                    and resp.request.method == "POST"
                )

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

        # The Client downloads asynchronously and writes into bk_assets/.
        downloaded = _wait_for_download(assets_dir, before, DOWNLOAD_TIMEOUT_S)
        assert downloaded, (
            f"No asset file appeared under {assets_dir} within {DOWNLOAD_TIMEOUT_S}s.\n"
            f"Godot output tail:\n{''.join(running_godot.lines[-40:])}"
        )
    finally:
        _cleanup_new(assets_dir, before)


def _wait_for_download(assets_dir: str, before: set, timeout_s: int):
    """Wait until a new, non-empty, size-stable file appears in assets_dir."""
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        new = [f for f in (_all_files(assets_dir) - before) if os.path.getsize(f) > 0]
        if new:
            sizes = {f: os.path.getsize(f) for f in new}
            time.sleep(2)  # let an in-progress download settle
            if all(
                os.path.exists(f) and os.path.getsize(f) == sizes[f] for f in new
            ):
                return new
        time.sleep(2)
    return None


def _cleanup_new(assets_dir: str, before: set):
    """Remove files (and now-empty dirs) this test created, so re-runs are deterministic."""
    for f in _all_files(assets_dir) - before:
        try:
            os.remove(f)
        except OSError:
            pass
    for dirpath, _dirs, _files in os.walk(assets_dir, topdown=False):
        if dirpath != assets_dir and not os.listdir(dirpath):
            try:
                os.rmdir(dirpath)
            except OSError:
                pass
