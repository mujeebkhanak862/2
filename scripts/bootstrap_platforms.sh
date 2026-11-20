#!/usr/bin/env bash
# Item 2: Flutter-generated platform scaffolding (gradlew, .metadata,
# windows/linux generated files) ZIP mein nahi hai. Yeh script unhe
# generate karti hai bina existing files overwrite kiye.
set -euo pipefail
cd "$(dirname "$0")/../shared_app"
flutter --version
# `flutter create .` sirf missing files banata hai; existing files
# (lib/, android/app/src/main, windows/runner, linux/*.cc) ko chhoota nahi.
flutter create --platforms=android,windows,linux --project-name shared_app .
echo "Ab `git diff` se check karein ki koi custom file overwrite na hui ho."
flutter pub get
flutter analyze
flutter test
