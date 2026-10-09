@tool
extends RefCounted
## Blendkit logo and icons rendered from SVG at the editor scale.

# Monochrome editor tab icon, drawn in #e0e0e0 like the built-in editor icons.
const ICON_PATH = "res://addons/blendkit/logo/blendkit-icon.svg"
const LOGO_PATH = "res://addons/blendkit/logo/blendkit-logo-hexa_pure.svg"
const LOGO_SVG_SIZE = 320.0


## Renders the SVG at [param scale] times its size, e.g. the editor scale for
## a 16 px icon, so it stays crisp. Monochrome icons turn dark on light themes.
static func render_svg(path: String, scale: float, monochrome := false) -> Texture2D:
	var svg := FileAccess.get_file_as_string(path)
	if monochrome and not is_dark_icon_theme():
		# Same conversion as Godot does for its own icons on light themes.
		svg = svg.replace("#e0e0e0", "#5a5a5a")
	var image := Image.new()
	if svg.is_empty() or image.load_svg_from_string(svg, scale) != OK:
		return null
	return ImageTexture.create_from_image(image)


## The colored Blendkit logo, [param px] pixels wide.
static func render_logo(px: float) -> Texture2D:
	return render_svg(LOGO_PATH, px / LOGO_SVG_SIZE)


# Mirrors EditorThemeManager::is_dark_icon_and_font(): light icons and fonts
# on a dark theme.
static func is_dark_icon_theme() -> bool:
	var settings := EditorInterface.get_editor_settings()
	match settings.get_setting("interface/theme/icon_and_font_color"):
		1: return false # dark icons
		2: return true # light icons
	var base_color: Color = settings.get_setting("interface/theme/base_color")
	return base_color.get_luminance() < 0.5
