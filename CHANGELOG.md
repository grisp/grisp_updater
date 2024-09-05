# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [2.0.0] - 2024-09-05

### Fixed

 - Fix file truncating causing image file in dummy system to be badly
   truncated [grisp/#10](https://github.com/grisp/grisp_updater/pull/10)
 - Fix comments and type spec typos [grisp/#10](https://github.com/grisp/grisp_updater/pull/10)
 
### Changed

 - Changed the grisp_updater_system behaviour's system_get_active/1 callback to
   system_get_systems/1 to add support for software updates from removable
   media [grisp/#10](https://github.com/grisp/grisp_updater/pull/10)
 - Pass the target record to grisp_updater_storage behaviour's storage_prepare
   callback so it can use the target size and total size for boundary checks
   and file truncating [grisp/#10](https://github.com/grisp/grisp_updater/pull/10)

### Added

 - Add grisp_updater:info/0 to get context-free update information [grisp/#10](https://github.com/grisp/grisp_updater/pull/10)
 - Add grisp_updater:info/1 to get update information in the context
   of a specific software update package [grisp/#10](https://github.com/grisp/grisp_updater/pull/10)
 - Add optional total size field to target record to allow boundary checks and
   fix file truncating [grisp/#10](https://github.com/grisp/grisp_updater/pull/10)
 - Add development-time macro USE_UNSEALED_MANIFEST. It makes the update manager
   retrieve the unsealed MANIFEST file instead of the sealed version
   MANIFEST.sealed, and do not perform any verification. Used for testing the
   manifest at development time without having to seal it every time [grisp/#10](https://github.com/grisp/grisp_updater/pull/10)

## [1.0.0] - 2024-08-07

First release.

[Unreleased]: https://github.com/grisp/grisp_updater/compare/2.0.0...HEAD
[2.0.0]: https://github.com/grisp/grisp_updater/compare/1.0.0...2.0.0
[1.0.0]: https://github.com/grisp/grisp_updater/compare/5647c909d388910503e3b9395b03cc55d879e64b...1.0.0
