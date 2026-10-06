"""Tests for the optional Blendkit login."""

from pathlib import Path

from .conftest import PROJECT_DIR
from .test_gallery import run_godot_script

ROOT = Path(PROJECT_DIR)

AUTH_CHECKS = r"""extends SceneTree

const Auth = preload("res://addons/blendkit/auth.gd")
const AccountButton = preload("res://addons/blendkit/ui/gallery/account_button.gd")

var failures := 0

func check(ok: bool, what: String) -> void:
    if not ok:
        failures += 1
        print("CHECK FAILED: " + what)

func _initialize():
    # RFC 7636 appendix B
    var challenge := Auth.pkce_challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
    check(challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", challenge)
    var verifier := Auth.new_pkce_verifier()
    check(verifier.length() == 128, "verifier length")
    check(RegEx.create_from_string("^[A-Za-z0-9]+$").search(verifier) != null, verifier)
    check(Auth.new_pkce_verifier() != verifier, "random verifier")

    var url := Auth.authorize_url("https://blendkit.com", "62485", "st", "ch", false)
    check(url == "https://blendkit.com/o/authorize?client_id=" + Auth.OAUTH_CLIENT_ID + "&response_type=code&state=st&redirect_uri=http://localhost:62485/consumer/exchange/&code_challenge=ch&code_challenge_method=S256", url)
    var signup := Auth.authorize_url("https://blendkit.com", "62485", "st", "ch", true)
    check(signup.begins_with("https://blendkit.com/accounts/register/?next=%2Fo%2Fauthorize%3Fclient_id%3D"), signup)
    check(not signup.substr(signup.find("next=")).contains("&"), "next is one parameter")

    var day := 24 * 3600.0
    check(not Auth.needs_refresh(1000.0 + 4 * day, 1000.0), "fresh token")
    check(Auth.needs_refresh(1000.0 + 2 * day, 1000.0), "token near expiry")
    check(Auth.is_rejected_refresh("Failed to refresh token: Wrong response status: 400 Bad Request"), "rejected")
    check(not Auth.is_rejected_refresh("Failed to refresh token: Making request error: dial tcp"), "network error")

    check(Auth.plan_label({}) == "", "unknown plan")
    check(Auth.plan_label({"currentPlanName": "Free", "hasFreePlan": true}) == "Free", "free")
    check(Auth.plan_label({"currentPlanName": "Full", "hasFreePlan": false}) == "Full Plan", "full")
    check(Auth.plan_label({"currentPlanName": "Full Plan"}) == "Full Plan", "full plan")
    check(Auth.plan_label({"currentPlanName": null, "hasFreePlan": true}) == "Free", "null name")
    check(Auth.display_name({"fullName": " ", "username": "ann"}) == "ann", "username fallback")
    check(Auth.display_name({"fullName": null}) == "", "no name")

    var image := Image.create(8, 6, false, Image.FORMAT_RGB8)
    image.fill(Color.RED)
    var round := AccountButton.circle_crop(image)
    check(round.get_size() == Vector2i(6, 6), str(round.get_size()))
    check(round.get_pixel(0, 0).a == 0.0, "corner transparent")
    check(round.get_pixel(3, 3).a == 1.0, "center opaque")

    if failures == 0:
        print("AUTH_CHECKS_PASSED")
    quit(failures)
"""


def test_auth_helpers(godot_executable, tmp_path):
    result = run_godot_script(godot_executable, tmp_path, ROOT, AUTH_CHECKS)
    output = result.stdout + result.stderr
    assert result.returncode == 0, output
    assert "AUTH_CHECKS_PASSED" in result.stdout, output
    assert "SCRIPT ERROR" not in result.stderr, output
