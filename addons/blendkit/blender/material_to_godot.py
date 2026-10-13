"""Convert the material of a Blendkit material .blend into a Godot material.

Run by the Blendkit Client's /run_blender_script under headless Blender,
with a JSON file of params as the last argument:
    input_path   : str - the material .blend
    output_path  : str - where to write the StandardMaterial3D .tres
    textures_dir : str - where to write its textures, next to output_path

The Principled BSDF's inputs map onto StandardMaterial3D, with its textures
copied as they are, and the height of the Displacement output as a height
map. Textures through nodes Godot has no counterpart for, like color ramps,
are left out, or kept without the node's change where that's close, like a
base color through a Hue/Saturation node. Materials without a Principled
BSDF become their viewport color.

With the texture size known from Blendkit, the material maps the textures
triplanar in object space, at their real size, so it fits any mesh without
UVs, e.g. a CSG box. Godot has no height mapping with triplanar mapping, so
the height map is there but off, to turn on along with turning triplanar
mapping off.

Each texture gets the import settings Godot would switch it to on seeing it
used in the material, so that it's imported once, with no messages about
the change.

Writes the .tres last, so its existence means success. Blender exits with 0
even when a script fails, so failures exit with 1 for the Client to report
them.
"""

import json
import os
import posixpath
import re
import shutil
import sys
import traceback

import bpy

# Godot imports these as they are, others are re-saved as PNG.
GODOT_IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".webp", ".exr", ".hdr", ".tga", ".bmp"}
# BaseMaterial3D.TextureChannel
RED, GREEN, BLUE, ALPHA, GRAYSCALE = range(5)
# BaseMaterial3D.Transparency and CullMode
ALPHA_BLEND, ALPHA_SCISSOR = 1, 2
CULL_DISABLED = 2
# ResourceImporterTexture options
VRAM_COMPRESSED = 2
NORMAL_MAP_ENABLE, NORMAL_MAP_DISABLED = 1, 2
ROUGHNESS_DISABLED, ROUGHNESS_RED = 1, 2
# Nodes that only adjust a color: the texture through them is kept, without
# the adjustment, for the base and emission colors.
COLOR_ADJUSTMENTS = {"ShaderNodeHueSaturation", "ShaderNodeBrightContrast", "ShaderNodeGamma",
                     "ShaderNodeRGBCurve"}
SEPARATE_NODES = {"ShaderNodeSeparateColor", "ShaderNodeSeparateRGB"}
MIX_NODES = {"ShaderNodeMix", "ShaderNodeMixRGB"}


def warn(message):
    print("Blendkit: " + message)


def socket(node, *names):
    """The node's input with the first of [names] it has: names differ
    between Blender versions, e.g. Emission (3.x) and Emission Color (4.0)."""
    for name in names:
        found = node.inputs.get(name)
        if found is not None:
            return found
    return None


def source(sock):
    """The output linked into [sock] through reroutes, or None."""
    while sock is not None and sock.is_linked:
        link = sock.links[0]
        if not link.is_valid or link.is_muted:
            return None
        if link.from_node.bl_idname != "NodeReroute":
            return link.from_socket
        sock = link.from_node.inputs[0]
    return None


class Converter:
    def __init__(self, output_path, textures_dir):
        self.output_dir = os.path.dirname(output_path)
        self.textures_dir = textures_dir
        # image name -> relative path, or None if it can't be written
        self.written = {}
        self.ext_resources = []
        self.props = {}
        # Image Texture nodes of the textures used
        self.texture_nodes = []
        # texture path -> {prop: channel} of the props it's the texture of
        self.uses = {}
        self.albedo_image = None
        # the bump node on the normal, and the height map's scale
        self.bump = None
        self.height_scale = None

    # MARK: textures

    def texture(self, image):
        """The ExtResource of [image], written to the textures folder once,
        or None."""
        if image.name not in self.written:
            self.written[image.name] = self.write_image(image)
        path = self.written[image.name]
        if path is None:
            return None
        if path not in self.ext_resources:
            self.ext_resources.append(path)
        return 'ExtResource("%d")' % (self.ext_resources.index(path) + 1)

    def write_image(self, image):
        name = os.path.basename(bpy.path.abspath(image.filepath)) or image.name
        stem, ext = os.path.splitext(re.sub(r'[\\/:*?"<>|]', "_", name))
        ext = ext.lower()
        if ext not in GODOT_IMAGE_EXTENSIONS:
            ext = ".png"
        target = os.path.join(self.textures_dir, stem + ext)
        n = 1
        while os.path.exists(target):
            n += 1
            target = os.path.join(self.textures_dir, "%s_%d%s" % (stem, n, ext))
        os.makedirs(self.textures_dir, exist_ok=True)
        try:
            if ext != os.path.splitext(name)[1].lower():
                settings = bpy.context.scene.render.image_settings
                settings.file_format = "PNG"
                settings.color_mode = "RGBA"
                image.save_render(target)
            elif image.packed_file:
                with open(target, "wb") as f:
                    f.write(image.packed_file.data)
            else:
                shutil.copyfile(bpy.path.abspath(image.filepath, library=image.library), target)
        except (OSError, RuntimeError) as e:
            warn("Left out image %s: %s" % (image.name, e))
            return None
        return os.path.relpath(target, self.output_dir).replace(os.sep, "/")

    def image_source(self, sock, colors=False):
        """(image node, channel) linked into [sock], through separate color
        nodes, and color adjustments when [colors], or (None, None)."""
        out = source(sock)
        channel = GRAYSCALE
        while out is not None:
            node = out.node
            if node.bl_idname == "ShaderNodeTexImage":
                if node.image is None:
                    return None, None
                if out.name == "Alpha":
                    return node, ALPHA
                return node, channel
            if node.bl_idname in SEPARATE_NODES:
                channel = {"Red": RED, "R": RED, "Green": GREEN, "G": GREEN, "Blue": BLUE, "B": BLUE}.get(out.name)
                if channel is None:
                    break  # HSV or HSL
                out = source(socket(node, "Color", "Image"))
                continue
            if colors and node.bl_idname in COLOR_ADJUSTMENTS:
                warn("Kept the texture through %s without its change" % node.name)
                out = source(socket(node, "Color"))
                continue
            if colors and node.bl_idname in MIX_NODES:
                # e.g. ambient occlusion multiplied in, the first texture wins
                inputs = [s for s in node.inputs if s.type == "RGBA" and s.enabled]
                found = next((s for s in inputs if self.image_source(s, True)[0]), None)
                if found is None:
                    break
                warn("Kept one texture of %s" % node.name)
                out = source(found)
                continue
            break
        if out is not None:
            warn("Left out %s, through %s" % (sock.name, out.node.name))
        return None, None

    def map_texture(self, sock, prop, colors=False):
        """Set [prop]_texture to the texture linked into [sock], and its
        channel for scalar inputs. Returns whether there is one."""
        node, channel = self.image_source(sock, colors)
        ref = self.texture(node.image) if node else None
        if ref is None:
            return False
        self.props[prop + "_texture"] = ref
        if not colors:
            self.props[prop + "_texture_channel"] = channel
        self.texture_nodes.append(node)
        self.uses.setdefault(self.written[node.image.name], {})[prop] = channel
        if prop == "albedo":
            self.albedo_image = node.image
        return True

    # MARK: material

    def convert(self, material, size):
        self.props["resource_name"] = gd_string(material.name)
        bsdf = principled(material)
        if bsdf is None:
            warn("No Principled BSDF in %s, kept its viewport color" % material.name)
            self.props["albedo_color"] = gd_color(material.diffuse_color, srgb=False)
        else:
            self.convert_bsdf(bsdf)
        self.convert_height(material)
        self.convert_mapping(size)

    def convert_bsdf(self, bsdf):
        props = self.props
        base = socket(bsdf, "Base Color")
        if not self.map_texture(base, "albedo", colors=True):
            props["albedo_color"] = gd_color(base.default_value)
        metallic = socket(bsdf, "Metallic")
        if self.map_texture(metallic, "metallic"):
            props["metallic"] = 1.0
        elif metallic.default_value:
            props["metallic"] = metallic.default_value
        roughness = socket(bsdf, "Roughness")
        if not self.map_texture(roughness, "roughness"):
            props["roughness"] = roughness.default_value
        specular = socket(bsdf, "Specular IOR Level", "Specular")
        if specular is not None:
            # Both are 0.5 for the usual 4% reflectance.
            props["metallic_specular"] = min(max(specular.default_value, 0.0), 1.0)
        self.convert_normal(socket(bsdf, "Normal"))
        self.convert_emission(bsdf)
        self.convert_alpha(bsdf)

    def convert_normal(self, sock):
        out = source(sock)
        if out is not None and out.node.bl_idname == "ShaderNodeBump":
            # A normal map through a bump node keeps its normals.
            self.bump = out.node
            out = source(socket(out.node, "Normal"))
        if out is None or out.node.bl_idname != "ShaderNodeNormalMap":
            return
        node = out.node
        if node.space != "TANGENT":
            warn("Left out the %s normal map, Godot's are in tangent space" % node.space.lower())
            return
        if self.map_texture(socket(node, "Color"), "normal", colors=True):
            self.props["normal_enabled"] = True
            strength = socket(node, "Strength")
            if strength.default_value != 1.0:
                self.props["normal_scale"] = strength.default_value

    def convert_emission(self, bsdf):
        color = socket(bsdf, "Emission Color", "Emission")
        strength = socket(bsdf, "Emission Strength")
        energy = strength.default_value if strength is not None else 1.0
        textured = self.map_texture(color, "emission", colors=True)
        if not textured:
            if not any(color.default_value[:3]):
                return
            self.props["emission"] = gd_color(color.default_value)
        if energy <= 0:
            self.props.pop("emission_texture", None)
            self.props.pop("emission", None)
            return
        self.props["emission_enabled"] = True
        if energy != 1.0:
            self.props["emission_energy_multiplier"] = energy

    def convert_alpha(self, bsdf):
        alpha = socket(bsdf, "Alpha")
        node, channel = self.image_source(alpha)
        if node is not None:
            if channel != ALPHA or node.image != self.albedo_image:
                warn("Left out the alpha, Godot takes it from the base color's alpha")
                return
            # cutouts like leaves, seen from both sides
            self.props["transparency"] = ALPHA_SCISSOR
            self.props["cull_mode"] = CULL_DISABLED
        elif alpha.default_value < 1.0:
            self.props["transparency"] = ALPHA_BLEND
            self.props["cull_mode"] = CULL_DISABLED
            color = self.props.get("albedo_color", "Color(1, 1, 1, 1)")
            self.props["albedo_color"] = color.rsplit(",", 1)[0] + ", %s)" % gd_float(alpha.default_value)

    def convert_height(self, material):
        """The height map from the Displacement output, else from a bump
        node on the normal."""
        output = material_output(material)
        displacement = source(socket(output, "Displacement")) if output else None
        node = displacement.node if displacement else self.bump
        if node is None or node.bl_idname not in {"ShaderNodeDisplacement", "ShaderNodeBump"}:
            return
        if self.map_texture(socket(node, "Height"), "heightmap"):
            self.props.pop("heightmap_texture_channel", None)
            scale = socket(node, "Scale", "Distance")
            self.height_scale = scale.default_value if scale is not None else None

    def convert_mapping(self, size):
        """Tile as a Mapping node on the textures' coordinates does, at the
        texture's real size where known."""
        scale = 1.0
        for node in self.texture_nodes:
            out = source(socket(node, "Vector"))
            if out is not None and out.node.bl_idname == "ShaderNodeMapping":
                sock = socket(out.node, "Scale")
                if sock is not None and not sock.is_linked:
                    scale = (sock.default_value[0] + sock.default_value[1]) / 2
                break
        if size:
            # Godot's height map scale is a hundredth of the texture's size.
            if self.height_scale is not None:
                self.props["heightmap_scale"] = self.height_scale * scale / size * 100
            scale /= size
            self.props["uv1_triplanar"] = True
        elif "heightmap_texture" in self.props:
            self.props["heightmap_enabled"] = True
        if scale != 1.0:
            self.props["uv1_scale"] = "Vector3(%s, %s, %s)" % ((gd_float(scale),) * 3)

    def imports(self):
        """{texture path: its .import}, as Godot makes it on seeing the
        texture used in 3D: VRAM compressed with mipmaps, RG compressed for
        normal maps, and for the roughness map, its roughness limited by
        the normal map. Godot's detection takes other textures for roughness
        maps too, so their limiter is disabled."""
        normal = next((path for path, uses in self.uses.items() if "normal" in uses), None)
        files = {}
        for path, uses in self.uses.items():
            params = {"compress/mode": VRAM_COMPRESSED,
                      "compress/normal_map": NORMAL_MAP_ENABLE if "normal" in uses else NORMAL_MAP_DISABLED,
                      "mipmaps/generate": True, "roughness/mode": ROUGHNESS_DISABLED,
                      "detect_3d/compress_to": 0}
            if "roughness" in uses and normal not in (None, path):
                params["roughness/mode"] = ROUGHNESS_RED + uses["roughness"]
                # relative to the texture, made a project path as it moves
                # into the project, see ProjectAssets._move_dir()
                params["roughness/src_normal"] = gd_string(posixpath.relpath(normal, posixpath.dirname(path)))
            lines = ["[remap]", "", 'importer="texture"', 'type="CompressedTexture2D"', "", "[params]", ""]
            lines += ["%s=%s" % (key, gd_value(value)) for key, value in params.items()]
            files[path] = "\n".join(lines) + "\n"
        return files

    def tres(self):
        lines = ['[gd_resource type="StandardMaterial3D" format=3]', ""]
        for i, path in enumerate(self.ext_resources):
            lines.append('[ext_resource type="Texture2D" path=%s id="%d"]' % (gd_string(path), i + 1))
        if self.ext_resources:
            lines.append("")
        lines.append("[resource]")
        for prop, value in self.props.items():
            lines.append("%s = %s" % (prop, gd_value(value)))
        return "\n".join(lines) + "\n"


# MARK: material nodes

def material_output(material):
    if not material.use_nodes or material.node_tree is None:
        return None
    tree = material.node_tree
    for target in ("EEVEE", "ALL", "CYCLES"):
        node = tree.get_output_node(target)
        if node is not None:
            return node
    return None


def principled(material):
    """The Principled BSDF making the surface, the first one through mix
    and add shaders."""
    output = material_output(material)
    pending = [source(socket(output, "Surface"))] if output else []
    while pending:
        out = pending.pop(0)
        if out is None:
            continue
        node = out.node
        if node.bl_idname == "ShaderNodeBsdfPrincipled":
            return node
        if node.bl_idname in {"ShaderNodeMixShader", "ShaderNodeAddShader"}:
            pending.extend(source(s) for s in node.inputs if s.type == "SHADER")
    return None


def asset_material(path):
    """Append the material asset from the .blend at [path], or its first
    material for files without asset marks."""
    with bpy.data.libraries.load(path, link=False, assets_only=True) as (src, dst):
        dst.materials = list(src.materials[:1])
    if not dst.materials:
        with bpy.data.libraries.load(path, link=False) as (src, dst):
            dst.materials = list(src.materials)
    materials = [m for m in dst.materials if m is not None]
    if not materials:
        raise RuntimeError("No material in %s" % path)
    return max(materials, key=lambda m: "blenderkit" in m.keys())


def texture_size(material):
    """The real size of the texture in meters, from Blendkit's upload data."""
    data = material.get("blenderkit")
    try:
        size = float(data.get("texture_size_meters", 0)) if data else 0.0
    except (TypeError, ValueError):
        return None
    return size if size > 0 else None


# MARK: Godot text format

def linear_to_srgb(c):
    c = max(c, 0.0)
    return c * 12.92 if c < 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055


def gd_float(value):
    return ("%.6g" % value) if value != int(value) else "%d" % value


def gd_color(rgba, srgb=True):
    """A Godot color from Blender's linear one: Godot's material colors are
    sRGB. The viewport color is sRGB already."""
    rgb = [linear_to_srgb(c) if srgb else c for c in rgba[:3]]
    alpha = rgba[3] if len(rgba) > 3 else 1.0
    return "Color(%s)" % ", ".join(gd_float(c) for c in rgb + [alpha])


def gd_string(text):
    return json.dumps(text, ensure_ascii=False)


def gd_value(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, float):
        return gd_float(value)
    return str(value)


def main():
    with open(sys.argv[-1], encoding="utf-8") as f:
        params = json.load(f)
    material = asset_material(params["input_path"])
    converter = Converter(params["output_path"], params["textures_dir"])
    converter.convert(material, texture_size(material))
    for path, text in converter.imports().items():
        with open(os.path.join(converter.output_dir, path + ".import"), "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
    with open(params["output_path"], "w", encoding="utf-8", newline="\n") as f:
        f.write(converter.tres())


try:
    main()
except Exception:
    traceback.print_exc()
    sys.exit(1)
