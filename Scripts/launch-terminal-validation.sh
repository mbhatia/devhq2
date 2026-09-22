#!/bin/zsh
# Launch an isolated, visibly distinct DevHQ instance for terminal validation.
set -euo pipefail

repo_root=${0:A:h:h}
validation_home=${DEVHQ_VALIDATION_HOME:-"$repo_root/.build/devhq-terminal-validation-home"}
validation_bundle="$repo_root/.build/DevHQ-Terminal-Validation.app"
configuration=${DEVHQ_VALIDATION_CONFIGURATION:-release}
swift_arguments=(run --configuration "$configuration" --jobs 4)

if [[ ${DEVHQ_VALIDATION_SKIP_BUILD:-0} == 1 ]]; then
  swift_arguments+=(--skip-build)
fi

mkdir -p "$validation_home/.config" "$validation_home/.cache" "$validation_home/Library/Preferences"
if pgrep -f "$validation_bundle/Contents/MacOS/DevHQ Terminal Validation" >/dev/null; then
  print -u2 "DevHQ Terminal Validation is already running; quit it before relaunching."
  exit 1
fi
rm -rf "$validation_bundle"

# Use DevHQ's explicit state directories: macOS home-directory APIs do not
# necessarily honor HOME. HOME also isolates any standard preferences.
export HOME="$validation_home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_CACHE_HOME="$HOME/.cache"
export DEVHQ_CONFIG_DIR="$XDG_CONFIG_HOME/devhq"
export DEVHQ_CACHE_DIR="$XDG_CACHE_HOME/devhq"
export DEVHQ_APP_NAME="DevHQ Terminal Validation"
export DEVHQ_VALIDATION_BUNDLE_PATH="$validation_bundle"
export DEVHQ_VALIDATION_WORKSPACE="$repo_root"

cd "$repo_root"
exec swift "${swift_arguments[@]}" DevHQ --workspace "$repo_root" "$@"
