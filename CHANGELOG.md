# Changelog

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
