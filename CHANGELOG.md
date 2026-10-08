# Changelog

## Unreleased

### Added

- **Blendkit** tab in the editor's top bar, next to **Asset Store**: search
  Blendkit assets with filters, page through thumbnails, open asset details,
  and download free assets straight into `bk_assets/`. Full Plan assets link to
  blendkit.com, where **Send to Godot** gets them.
- Optional login from the **Blendkit** tab: **Log In…** in the Blendkit menu
  logs in through the browser like the Blender add-on, turning the Client on
  if needed. With a Full Plan account, Full Plan assets download straight
  into the project.
- Blendkit menu at the end of the search bar: the Blendkit logo with a Client
  status dot and **⋮** opens the Client status and switch, the account
  (avatar, name, email and plan, or **Log In…** and **Sign Up…**),
  **Settings…** and links to blendkit.com, the docs and the issue tracker.
- Asset thumbnails show download progress along their bottom edge, and a
  check mark or an error icon when the download finishes.
- Project assets: the download toggle next to the search switches the
  **Blendkit** tab to the assets downloaded to the project, including those
  sent with **Send to Godot**, with a local search and **Show in FileSystem**.
  Asset folders found in `bk_assets/` are looked up on blendkit.com and
  remembered in `.godot/blendkit/`, so nothing is added to the project.
  Switching back returns to the previous search instantly.
- The download toggle shows the number of downloads in progress, and the
  project assets list them first with their progress, including **Send to
  Godot** downloads from blendkit.com.

### Removed

- The **Blendkit** dock next to **Inspector**. Its status and Client switch
  moved to the Blendkit menu, its settings to **Settings…** in that menu, and
  download progress to the asset thumbnails and details. Downloads started
  with **Send to Godot** on blendkit.com show in the editor Output.

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
