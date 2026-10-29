#!/bin/zsh
# Generates MONO.xcodeproj from project.yml using your own team and bundle id prefix from tools/local.env.
cd "${0:A:h}/.." || exit 1
[[ -f tools/local.env ]] && source tools/local.env
export DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
export BUNDLE_ID_PREFIX="${BUNDLE_ID_PREFIX:-com.example}"
exec xcodegen generate
