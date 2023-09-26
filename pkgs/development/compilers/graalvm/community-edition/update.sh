#!/usr/bin/env nix-shell
#!nix-shell -p coreutils curl.out nix jq gnused -i bash

# Usage:
# ./update.sh [PRODUCT]
#
# Examples:
#   $ ./update.sh graalvm-ce # will generate ./hashes-graalvm-ce.nix
#   $ ./update.sh # same as above
#   $ ./update.sh graalpy # will generate ./hashes-graalpy.nix
#
# Environment variables:
# FORCE=1        to force the update of a product (e.g.: skip up-to-date checks)
# VERSION=xx.xx  will assume that xx.xx is the new version

set -eou pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
tmpfile="$(mktemp --suffix=.nix)"

trap 'rm -rf "$tmpfile"' EXIT

info() { echo "[INFO] $*"; }

echo_file() { echo "$@" >> "$tmpfile"; }

verlte() {
    [  "$1" = "$(echo -e "$1\n$2" | sort -V | head -n1)" ]
}

readonly product="${1:-graalvm-ce}"
readonly hashes_nix="hashes-$product.nix"
readonly nixpkgs=../../../../..

declare -r -A update_urls=(
  [graalvm-ce]="https://api.github.com/repos/graalvm/graalvm-ce-builds/releases/latest"
  [graaljs]="https://api.github.com/repos/oracle/graaljs/releases/latest"
  [graalnodejs]="https://api.github.com/repos/oracle/graaljs/releases/latest"
  [graalpy]="https://api.github.com/repos/oracle/graalpython/releases/latest"
  [truffleruby]="https://api.github.com/repos/oracle/truffleruby/releases/latest"
)

current_version="$(nix-instantiate "$nixpkgs" --eval --strict -A "graalvmCEPackages.${product}.version" --json | jq -r)"
readonly current_version

if [[ -z "${VERSION:-}" ]]; then
  gh_version="$(curl \
      ${GITHUB_TOKEN:+"-u \":$GITHUB_TOKEN\""} \
      -s "${update_urls[$product]}" | \
      jq --raw-output .tag_name)"
  new_version="${gh_version//jdk-/}"
  new_version="${new_version//graal-/}"
else
  new_version="$VERSION"
fi
readonly new_version

info "Current version: $current_version"
info "New version: $new_version"
if verlte "$new_version" "$current_version"; then
  info "$product $current_version is up-to-date."
  [[ -z "${FORCE:-}" ]]  && exit 0
else
  info "$product $current_version is out-of-date. Updating..."
fi

# Make sure to get the `-community` versions!
declare -r -A products_urls=(
  [graalvm-ce]="https://github.com/graalvm/graalvm-ce-builds/releases/download/jdk-${new_version}/graalvm-community-jdk-${new_version}_@platform@_bin.tar.gz"
  [graaljs]="https://github.com/oracle/graaljs/releases/download/graal-${new_version}/graaljs-community-${new_version}-@platform@.tar.gz"
  [graalnodejs]="https://github.com/oracle/graaljs/releases/download/graal-${new_version}/graalnodejs-community-${new_version}-@platform@.tar.gz"
  [graalpy]="https://github.com/oracle/graalpython/releases/download/graal-${new_version}/graalpy-community-${new_version}-@platform@.tar.gz"
  [truffleruby]="https://github.com/oracle/truffleruby/releases/download/graal-${new_version}/truffleruby-community-${new_version}-@platform@.tar.gz"
)

if [[ "$product" == "graalvm-ce" ]]; then
  readonly platforms=(
    "linux-aarch64"
    "linux-x64"
    "macos-aarch64"
    "macos-x64"
  )
else
  readonly platforms=(
    "linux-aarch64"
    "linux-amd64"
    "macos-aarch64"
    "macos-amd64"
  )
fi

info "Generating '$hashes_nix' file for '$product' $new_version. This will take a while..."

# Indentation of `echo_file` function is on purpose to make it easier to visualize the output
echo_file "# Generated by $0 script"
echo_file "{"
echo_file "  \"version\" = \"$new_version\";"
url="${products_urls["${product}"]}"
echo_file "  \"$product\" = {"
for platform in "${platforms[@]}"; do
  args=("${url//@platform@/$platform}")
  # Get current hashes to skip derivations already in /nix/store to reuse cache when the version is the same
  # e.g.: when adding a new product and running this script with FORCE=1
  if [[ "$current_version" == "$new_version" ]] && \
      previous_hash="$(nix-instantiate --eval "$hashes_nix" -A "$product.$platform.sha256" --json | jq -r)"; then
      args+=("$previous_hash" "--type" "sha256")
  else
      info "Hash in '$product' for '$platform' not found. Re-downloading it..."
  fi
  if hash="$(nix-prefetch-url "${args[@]}")"; then
echo_file "    \"$platform\" = {"
echo_file "      sha256 = \"$hash\";"
echo_file "      url = \"${url//@platform@/${platform}}\";"
echo_file "    };"
  else
      info "Error while downloading '$product' for '$platform'. Skipping it..."
  fi
done
echo_file "  };"
echo_file "}"

info "Moving the temporary file to '$hashes_nix'"
mv "$tmpfile" "$hashes_nix"

info "Done!"
