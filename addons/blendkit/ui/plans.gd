@tool
extends RefCounted
## Blendkit plans in the colors of blendkit.com/plans/pricing: badges for an
## asset's or an account's plan and buttons leading to the plans. The colors
## stay the same in every editor theme, like on the website.

## Background and text color of each plan.
const COLORS := {
	"free": [Color("6d7e31"), Color.WHITE],
	"full": [Color("b35935"), Color.WHITE],
	"business": [Color("e0f0fd"), Color.BLACK],
}
const ASSET_LABELS := {"free": "Free", "full": "Full Plan"}
## Padding around the badge text, and the badge's inset from the corner.
const BADGE_PADDING := Vector2(10, 4)
const BADGE_INSET := 6
const BUTTON_STATES := ["normal", "hover", "pressed", "hover_pressed"]
const BUTTON_FONT_COLORS := ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]


## "free" or "full", "" for assets in the project not found on Blendkit.
static func asset_plan(asset: Dictionary) -> String:
	if not asset.has("isFree"):
		return ""
	return "free" if asset.isFree == true else "full"


## "free", "full" or "business" for the account, "" when unknown. Blendkit
## names its plans "Free", "Full" and "Business".
static func user_plan(user: Dictionary) -> String:
	if user.get("hasFreePlan") == true:
		return "free"
	var plan := str(user.get("currentPlanName", "")).strip_edges().to_lower() if user.get("currentPlanName") else ""
	plan = plan.trim_suffix(" plan")
	return plan if COLORS.has(plan) else ""


## Show [param text] on a rounded badge in the plan's color, or hide the label
## for an unknown plan.
static func style_badge(label: Label, plan: String, text: String) -> void:
	label.visible = COLORS.has(plan)
	if not label.visible:
		return
	label.text = text
	var edscale := EditorInterface.get_editor_scale()
	var box := StyleBoxFlat.new()
	box.bg_color = COLORS[plan][0]
	# fully rounded ends, the radius is clamped to the height
	box.set_corner_radius_all(int(100 * edscale))
	box.content_margin_left = BADGE_PADDING.x * edscale
	box.content_margin_right = BADGE_PADDING.x * edscale
	box.content_margin_top = BADGE_PADDING.y * edscale
	box.content_margin_bottom = BADGE_PADDING.y * edscale
	label.add_theme_stylebox_override("normal", box)
	label.add_theme_color_override("font_color", COLORS[plan][1])


## Put the badge in the bottom right corner of the image its parent shows
## centered at [param image_size], or of the parent itself, like on the
## thumbnails on blendkit.com. The image is inside the [param frame] margins.
static func place_badge(label: Label, image_size := Vector2.ZERO, frame: StyleBox = null) -> void:
	var gap := Vector2.ONE * BADGE_INSET * EditorInterface.get_editor_scale()
	var area := label.get_parent_area_size()
	if frame:
		area -= frame.get_minimum_size()
		gap += Vector2(frame.get_margin(SIDE_RIGHT), frame.get_margin(SIDE_BOTTOM))
	if image_size.x > 0 and image_size.y > 0:
		var fit := image_size * minf(area.x / image_size.x, area.y / image_size.y)
		gap += ((area - fit) / 2).floor()
	var badge := label.get_combined_minimum_size()
	label.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	label.offset_right = -gap.x
	label.offset_bottom = -gap.y
	label.offset_left = label.offset_right - badge.x
	label.offset_top = label.offset_bottom - badge.y


## Fill the button with the plan's color, or restore the theme's look for "".
static func style_button(button: Button, plan: String) -> void:
	for state in BUTTON_STATES:
		button.remove_theme_stylebox_override(state)
	for color in BUTTON_FONT_COLORS:
		button.remove_theme_color_override(color)
	if not COLORS.has(plan):
		return
	var base: StyleBox = button.get_theme_stylebox("normal")
	var bg: Color = COLORS[plan][0]
	var shades := {"normal": bg, "hover": bg.lightened(0.15), "pressed": bg.darkened(0.15), "hover_pressed": bg.darkened(0.15)}
	for state in shades:
		var box: StyleBoxFlat = base.duplicate() if base is StyleBoxFlat else StyleBoxFlat.new()
		if not base is StyleBoxFlat:
			box.content_margin_left = base.get_margin(SIDE_LEFT)
			box.content_margin_right = base.get_margin(SIDE_RIGHT)
			box.content_margin_top = base.get_margin(SIDE_TOP)
			box.content_margin_bottom = base.get_margin(SIDE_BOTTOM)
		box.bg_color = shades[state]
		box.border_color = shades[state]
		button.add_theme_stylebox_override(state, box)
	for color in BUTTON_FONT_COLORS:
		button.add_theme_color_override(color, COLORS[plan][1])


## [param icon] recolored to the plan's color, or null when that color
## wouldn't stand out on [param background], e.g. Business on a light theme.
static func tint_icon(icon: Texture2D, plan: String, background: Color) -> Texture2D:
	if not COLORS.has(plan) or icon == null:
		return null
	var color: Color = COLORS[plan][0]
	if absf(color.get_luminance() - background.get_luminance()) < 0.3:
		return null
	var image := icon.get_image()
	if image == null:
		return null
	image.decompress()
	image.convert(Image.FORMAT_RGBA8)
	for y in image.get_height():
		for x in image.get_width():
			var a := image.get_pixel(x, y).a
			if a > 0.0:
				image.set_pixel(x, y, Color(color, a))
	return ImageTexture.create_from_image(image)
