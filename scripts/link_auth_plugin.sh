#!/usr/bin/env bash
#
# Makes gke-gcloud-auth-plugin resolvable from a plain interactive shell, not
# just from inside `just` recipes (the justfile's own PATH export only covers
# processes just launches directly -- it can't help a bare `kubectl` run later
# in your terminal, which execs the plugin itself using your shell's PATH).
#
# `gcloud components install gke-gcloud-auth-plugin` drops the binary under
# the SDK's own bin/, but neither Homebrew's gcloud cask nor gcloud itself
# symlinks it anywhere that's on PATH by default. `gcloud` itself IS on PATH
# though (that's how you're able to run `gcloud` at all), so symlink the
# plugin into the same directory gcloud already resolves from -- guaranteed
# writable (it's wherever gcloud's own symlink/binary already lives) and
# guaranteed to be on PATH.

# NOTE: don't gate this on `command -v gke-gcloud-auth-plugin` -- when this
# script runs as a `just` recipe, just has already exported its own PATH
# (including the SDK bin dir) into this process's environment, so that check
# would always report "found" here even when the target shell (yours) can't
# see it. Just always (idempotently) re-link instead.
#
# Same problem applies to finding gcloud's own directory: when run via `just`,
# PATH has the SDK bin dir prepended, so a naive `command -v gcloud` resolves
# to the SDK's own bin/ -- the exact directory `plugin_src` already lives in
# -- making src and dst the same path and silently no-op'ing. Strip the SDK
# root out of PATH first so this always finds the *other* gcloud (the one on
# your actual interactive shell's PATH, e.g. Homebrew's symlink) regardless
# of whether this script is invoked directly or through a `just` recipe.

set -euo pipefail

sdk_root="$(gcloud info --format='value(installation.sdk_root)')"
plugin_src="$sdk_root/bin/gke-gcloud-auth-plugin"

clean_path="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vF "$sdk_root" | tr '\n' ':')"
gcloud_bin_dir="$(dirname "$(PATH="$clean_path" command -v gcloud)")"
plugin_dst="$gcloud_bin_dir/gke-gcloud-auth-plugin"

if [ ! -e "$plugin_src" ]; then
  echo "gke-gcloud-auth-plugin isn't installed. Run: gcloud components install gke-gcloud-auth-plugin" >&2
  exit 1
fi

if [ -e "$plugin_dst" ] || [ -L "$plugin_dst" ]; then
  exit 0
fi

ln -s "$plugin_src" "$plugin_dst"
echo "Linked gke-gcloud-auth-plugin into $gcloud_bin_dir -- kubectl will find it from any shell now."
