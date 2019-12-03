#!/bin/bash

set -euo pipefail

if [ "${PUBLISH_TO_RUBYGEMS:-}" == "" ]; then
  echo "Skipping because this build is not the nightly RubyGems scheduled build"
  exit 0
fi

git_commit_count=$(git rev-list --count HEAD)
prefix="0.4"
release_version="$prefix.${git_commit_count}"

echo "--- Dowloading artifacts"
rm -rf release
rm -rf _out_
buildkite-agent artifact download "_out_/**/*" .

echo "+++ Publishing to RubyGems.org"

mkdir -p "$HOME/.gem"
printf -- $'---\n:rubygems_api_key: %s\n' "$SORBET_RUBYGEMS_API_KEY" > "$HOME/.gem/credentials"
chmod 600 "$HOME/.gem/credentials"

# https://stackoverflow.com/a/8351489
with_backoff() {
  local attempts=5
  local timeout=1 # doubles each failure

  local attempt=0
  while true; do
    attempt=$(( attempt + 1 ))
    echo "Attempt $attempt"
    if "$@"; then
      return 0
    fi

    if (( attempt >= attempts )); then
      echo "'$1' failed $attempts times. Quitting." 1>&2
      exit 1
    fi

    echo "'$1' failed. Retrying in ${timeout}s..." 1>&2
    sleep $timeout
    timeout=$(( timeout * 2 ))
  done
}

# push the sorbet-static gems first, in case they fail. We don't want to end
# up in a weird state where 'sorbet' requires a pinned version of
# sorbet-static, but the sorbet-static gem push failed.
#
# (By failure here, we mean that RubyGems.org 502'd for some reason.)
# Push the linux gem
if ! gem fetch sorbet-static --platform x86_64-linux --version "$release_version" | grep -q "ERROR"; then
  with_backoff gem push --verbose "_out_/gems/sorbet-static-$release_version-x86_64-linux.gem"
fi

# Push the mac gem
if ! gem fetch sorbet-static --platform universal-darwin --version "$release_version" | grep -q "ERROR"; then
  with_backoff gem push --verbose "_out_/gems/sorbet-static-$release_version-universal-darwin-"*.gem
fi

# only publish the java gem if it exists 
# this script is run once again after the build-static-release-java.rb
if [ -f "_out_/gems/sorbet-static-$release_version-java.gem" ]; then
  if ! gem fetch sorbet-static --platform java --version "$release_version" | grep -q "ERROR"; then
    with_backoff gem push --verbose "_out_/gems/sorbet-static-$release_version-java.gem"
  fi
fi

if ! gem list --remote rubygems.org --exact 'sorbet-runtime' | grep -q "$release_version"; then
  with_backoff gem push --verbose "_out_/gems/sorbet-runtime-$release_version.gem"
fi

if ! gem list --remote rubygems.org --exact 'sorbet' | grep -q "$release_version"; then
  with_backoff gem push --verbose "_out_/gems/sorbet-$release_version.gem"
fi
