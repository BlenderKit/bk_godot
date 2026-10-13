# Changelog

## 0.7.1 - UNRELEASED

### Added

- Clicking the author in asset details shows their assets. An **Author**
  filter appears in the gallery filters, remove it to show all authors again.
- **UUIDs in Names** setting for how downloads are named. **Strip**, the
  default, leaves the UUIDs out: `models/chair/chair_gltf_godot.glb`. An asset
  with the name of another one gets a short UUID, and a newer version of an
  asset replaces the older one in its folder, so scenes using it keep working.
  **Short** keeps 8 characters of the UUIDs, **Full** all of them, as before.
  A hidden `.blendkit` file in each asset folder says which asset it is.
- HDRs import in Godot: Blender re-saves their lossy DWAA-compressed EXRs,
  which Godot can't read, as lossless ZIP-compressed EXRs before they move
  into the project. It uses the Blender set up for Blender Import, or one
  found on this computer. Without Blender, the original file is kept.

### Changed

- Asset details follow the blendkit.com layout: a bigger title with the asset
  type above it, the description under the preview, and one column of
  properties with score, quality and complexity and their icons, file size,
  license and date. Animated, Rigged and Procedural show only when they apply.
  Long descriptions scroll. The tags are a comma-separated list.
- Asset details open at their final size, without a jump in the first frame.
- The gallery **Sort** options match blendkit.com: Relevance, Trending, Most
  bookmarked, Highest asset score, Highest complexity, Highest quality and
  Newest.

- Asset details list the formats already downloaded to the project, marked
  with a check. **Show File** shows the selected downloaded file, in the
  FileSystem dock if Godot imports it, otherwise in the file manager. The
  other formats can still be downloaded. In the FileSystem dock, the Blendkit
  logo briefly points at the file.
- Asset details opened from project assets look the asset up on blendkit.com
  to offer the formats not downloaded yet. Offline, they show the downloaded
  ones.
- The file selector in asset details sits before the button it applies to.
- Plans show in the Blendkit colors, the same in every editor theme: Free and
  Full Plan badges in the corner of the previews in the gallery and in asset
  details, like on blendkit.com, an orange **Get Full Plan…** button, and a
  star in the plan's color next to your plan in the Blendkit menu, including
  Business Plan.

### Fixed

- Project assets support several downloaded formats per asset, e.g. glTF and
  .blend, instead of showing only the newest file.
- Project assets no longer pick textures Godot extracts from a .glb, such as
  .png or .webp, as the asset file.
- Downloading an asset whose files changed on Blendkit since the search no
  longer fails with a 404. The gallery looks the asset up again and retries
  once with its new files.

## 0.7.0 - 2026-10-12

The plugin moves into a new **Blendkit** main screen tab in the Godot editor,
with a built-in asset browser, project assets, integrated settings, login,
Blender import setup and more.

A web browser is no longer required; it's only needed for the optional login.
Relying on the Send to Godot button in modern browsers was the biggest pain
point, and the built-in asset browser now makes it unnecessary 😎

This release is packed with new features and polish, including UI that follows
Godot conventions: a huge leap forward in usability 🥳

### Added

- **Blendkit** tab in the editor's top bar, next to **Asset Store**: search
  Blendkit assets with filters, page through thumbnails, open asset details,
  and download assets straight into `bk_assets/`.
- **Polygons** filter for models and printables: a range slider from 0 to ∞
  with Min and Max boxes for exact counts and **Any** to clear it. The active
  filter reads **Any**, **> 1k**, **< 10k** or **10 - 10k**.
- Project assets: the download toggle next to the search bar switches the
  **Blendkit** tab to assets downloaded to the project, with a local search
  and **Show in FileSystem**.
  Asset folders found in `bk_assets/` are looked up on blendkit.com and cached
  in `.godot/blendkit/`, so nothing is added to the project. Switching back
  with the toggle or **Browse Blendkit** below the assets restores the
  previous search instantly.
- Blendkit menu at the end of the search bar, opened by the Blendkit logo with
  a Client status dot and **⋮**: Client status and switch, account (avatar,
  name, email and plan, or **Log In…** and **Sign Up…**), **Settings**, and
  links to blendkit.com, **User Guide**, **README & Sources** and the issue
  tracker.
- Optional login: **Log In…** in the Blendkit menu logs in through the
  browser like the Blender add-on, turning the Client on if needed. With a
  Full Plan account, Full Plan assets download straight into the project.
- **Blender Import** line in **Settings** shows how Godot imports .blend
  files and warns when Blender isn't set up. Clicking it opens a dialog to
  choose between **Don't import .blend** and **Native .blend import**. Native
  import needs Blender: **Detect** finds it, or set it with a file picker;
  Apply stays disabled until Blender works. **Apply & Restart** restarts the
  editor, since Godot sets up .blend import on startup.
- Downloads are staged in `bk_assets/.downloads/` and moved into place once
  complete, so Godot no longer tries to import partial files.
- Plugin and Client versions at the bottom of the Blendkit menu.

### Changed

- Use official signed Blendkit Client binaries v1.13.6 from standalone
  [bk_client](https://github.com/BlenderKit/bk_client) releases.
- **Model Format** options are renamed to **Blender (.blend)** and **glTF
  (.glb)**, both in the settings and in the **Blendkit** tab's Format filter.
- **Model Format** now defaults to **Blender (.blend)** instead of glTF.
  Projects that never changed it switch to .blend downloads; set it back to
  **glTF (.glb)** in **Settings** if you prefer glTF.
- **Auto** resolution now downloads 2K textures instead of the original
  full-resolution .blend.
- Settings are saved to Godot's **Project Settings** and **Editor Settings**
  under **Blendkit**, where they can be edited too. Download directory, Model
  Format and Resolution are per project in `project.godot`, shared with the
  team. Client Port, Log Level and the Client switch stay in your editor
  settings. Model Format and Resolution set in older versions are migrated.

### Removed

- The **Blendkit** dock next to **Inspector**. Its status and Client switch
  moved to the Blendkit menu, its settings to **Settings** in that menu, and
  download progress to the asset thumbnails and details.

## 0.6.1 - 2026-07-01

Tiny bugfix release to remove harmless Warning on startup for good.

### Changed

- No more `invalid UID` warning when the plugin loads: the resource `.uid`
  files were missing from the release archive, so Godot couldn't resolve
  UIDs and fell back to text paths. They are now shipped with the plugin.

## 0.6.0 - 2026-07-01

Major bugfix release ensuring compatibility with the new `blendkit.com` domain
and improving Client handling.

**Please upgrade** by removing the old `addons/blendkit/` directory and
unpacking the latest version.

You can now use the **Godot Asset Store** tab in Godot 4.7+ to install the plugin.

### Changed

- Use official signed Client binaries (v1.9.2) which include
  upstream fixes needed to work with new `blendkit.com` domain.
- Skip outdated Clients left running by other integrations and start the
  bundled Client instead, picking another known port if needed.

### Added

- The plugin is now available from the new **Godot Asset Store** included in
  Godot 4.7 and newer.
- Always use the highest-version Client binary, and warn if multiple versions
  are present — usually a sign the plugin was unpacked over an old copy instead
  of a clean reinstall.
- CI now tests the **Send to Godot** button on Linux and Windows to ensure
  better long-term stability.

## 0.5.2 - 2026-06-24

Utility release which adds `addons/blendkit/LICENSE` to comply with
Godot Asset Store requirements.

No functional changes.

### Added

- Include `LICENSE` in the `addons/blendkit/` directory so it ships with the
  addon. The root `LICENSE` remains the source of truth and is synced into the
  addon directory on build.

## 0.5.1 - 2026-06-22

Bugfix release for the `blenderkit.com` -> `blendkit.com` migration.

Older Clients (<= 1.9.0) will get CORS errors in the browser from `blendkit.com`
leading to the **Send to Godot** button not showing.

**Please upgrade** by removing old `addons/blendkit` directory and
unpacking the latest version.

### Changed

- Patched Client to send correct CORS for `blendkit.com`.

### Added

- New End-to-End (E2E) CI using Playwright which ensures the elusive **Send to Godot**
  button shows in a browser and triggers asset download in Godot. This is quite
  a comprehensive test of the entire stack which should hopefully bring
  more stability to the addon and detect breakages in production automatically.

## 0.5.0 - 2026-06-11

Renamed to **Blendkit** and improved Client connection stability.

### Changed

- New plugin name: **Blendkit**
  - New plugin directory: `addons/blendkit/`
  - On upgrade just delete old dir: `addons/blenderkit/`
- Improved Client discovery, connection stability, and state flow.
- Properly display reported Client's version.
- Suppress occasional harmless warning when Godot window got suspended.

## 0.4.2 - 2026-03-04

Tiny bugfix release to remove harmless Warning on startup.

### Changed

- Remove script uid reference which was causing a harmless warning. Just Godot things.

## 0.4.1 - 2026-03-03

Small bugfix/polish release improving Wayland integration.

### Added

- Add "Auto" and "Original" resolution options
- Unsubscribe from Client when disabled or in error state

### Changed

- Improve Client integration with high latency clients
  - This fixes disconnects on Wayland when Godot editor isn't visible
- Change default Log Level to INFO and clean up Output
- Fix alignment of the version label with docs links
