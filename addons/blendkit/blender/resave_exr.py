"""Re-save an OpenEXR image losslessly in a compression Godot imports.

Run by the Blendkit Client's /run_blender_script under headless Blender,
with a JSON file of params as the last argument:
    input_path  : str  - the EXR to convert
    output_path : str  - where to write the converted EXR
    alpha       : bool - whether to keep an alpha channel

Writes half float ZIP, the most widely read lossless EXR compression. Blender
exits with 0 even when a script fails, so failures exit with 1 for the
Client to report them.
"""

import json
import sys
import traceback

import bpy


def main():
    with open(sys.argv[-1], encoding="utf-8") as f:
        params = json.load(f)
    image = bpy.data.images.load(params["input_path"])
    settings = bpy.context.scene.render.image_settings
    settings.file_format = "OPEN_EXR"
    settings.exr_codec = "ZIP"
    settings.color_depth = "16"
    # Blender loads every image as RGBA, so the header says which to keep.
    settings.color_mode = "RGBA" if params.get("alpha") else "RGB"
    image.save_render(params["output_path"], scene=bpy.context.scene)


try:
    main()
except Exception:
    traceback.print_exc()
    sys.exit(1)
