# Universal Device Agent — GitHub Build Package

## Folder map
- `shared_app/`: canonical Flutter application used by the build workflow.
- `APK/shared_app/`: Android-specific copy retained for reference.
- `EXE/shared_app/`: Windows-specific copy retained for reference.
- `OS/shared_app/`: Linux-specific copy retained for reference.
- `control_api/` and `Backend/`: backend source copies.
- `web_dashboard/` and `Website/`: website/dashboard files.
- `.github/workflows/build-all.yml`: builds Android APK, Windows release bundle, and Linux bundle.
- `.github/workflows/run-build.yml`: manually starts the reusable build workflow after typing `build`.

## How to use
1. Extract this ZIP.
2. Upload the *contents* of this ZIP to the root of your GitHub repository, so `.github`, `shared_app`, `control_api`, etc. are directly at repository root. Do not upload the outer ZIP folder as a nested directory.
3. Open **Actions**. Enable workflows if GitHub asks.
4. Push to `main`/`master`, or open **Run Universal Device Agent Build** and type `build` to run it manually.
5. Download successful outputs from the workflow run's **Artifacts** section.

The build workflow uses `shared_app/` as the single canonical Flutter source to avoid accidentally building stale copies in `APK/`, `EXE/`, and `OS/`. The Windows and Linux workflows generate the missing Flutter-managed CMake scaffolding in a temporary template and copy only the managed `flutter/` directory, preserving the project's custom runner files.

Builds may still reveal source-code or native dependency errors; a workflow can fix paths and generate standard scaffolding but cannot guarantee that every custom feature compiles or runs on a real device. The Windows artifact is a release bundle directory, not a standalone installer EXE unless an installer step is added.
