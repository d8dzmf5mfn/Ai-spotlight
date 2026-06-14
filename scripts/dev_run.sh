#!/usr/bin/env bash
# Dev loop: build and run the app without packaging.
set -euo pipefail
cd "$(dirname "$0")/.."
swift run AISpotlight
