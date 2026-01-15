#!/usr/bin/env bash
set -e

echo "Checking Flutter..."

# Flutter nur klonen, wenn es noch NICHT existiert
if [ ! -d "flutter" ]; then
  echo "Installing Flutter..."
  git clone https://github.com/flutter/flutter.git -b stable
else
  echo "Flutter already installed, skipping clone"
fi

export PATH="$PATH:`pwd`/flutter/bin"

flutter --version

echo "Building Flutter web..."
flutter build web
