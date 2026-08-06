#!/bin/sh

set -eu

repository_url=${KNOWLEDGE_SDK_REPOSITORY_URL:-https://github.com/rozdol/knowledge-sdk.git}
repository_ref=${KNOWLEDGE_SDK_REF:-main}
install_mode=${KNOWLEDGE_SDK_INSTALL_MODE:-auto}

usage() {
  cat <<'EOF'
Install knowledge-sdk from its public Git repository.

Usage: install.sh [options]

Options:
  --ref REF       Install a branch, tag, or commit (default: main)
  --user          Install into the current user's RubyGems directory
  --system        Install into the active RubyGems directory
  -h, --help      Show this help

Environment:
  KNOWLEDGE_SDK_REPOSITORY_URL  Override the repository URL
  KNOWLEDGE_SDK_REF             Override the Git ref
  KNOWLEDGE_SDK_INSTALL_MODE    Set auto, user, or system
EOF
}

fail() {
  printf 'knowledge-sdk installer: %s\n' "$*" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --ref)
      [ "$#" -ge 2 ] || fail "--ref requires a value"
      repository_ref=$2
      shift 2
      ;;
    --user)
      install_mode=user
      shift
      ;;
    --system)
      install_mode=system
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1 (run with --help for usage)"
      ;;
  esac
done

case "$install_mode" in
  auto|user|system) ;;
  *) fail "install mode must be auto, user, or system" ;;
esac

for command_name in git ruby gem; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is required"
done

ruby_version=$(ruby -e 'print RUBY_VERSION')
ruby -e 'exit Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("2.6") ? 0 : 1' \
  -rrubygems || fail "Ruby 2.6 or newer is required (found $ruby_version)"

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/knowledge-sdk-install.XXXXXX") || \
  fail "could not create a temporary directory"
trap 'rm -rf "$temporary_root"' EXIT HUP INT TERM
source_root=$temporary_root/source

printf 'Fetching knowledge-sdk (%s)...\n' "$repository_ref"
git init -q "$source_root"
git -C "$source_root" remote add origin "$repository_url"
git -C "$source_root" fetch -q --depth 1 origin "$repository_ref" || \
  fail "could not fetch ref $repository_ref from $repository_url"
git -C "$source_root" checkout -q --detach FETCH_HEAD

[ -f "$source_root/knowledge-sdk.gemspec" ] || \
  fail "the fetched source does not contain knowledge-sdk.gemspec"
[ -f "$source_root/VERSION" ] || fail "the fetched source does not contain VERSION"

package_version=$(tr -d '[:space:]' < "$source_root/VERSION")
[ -n "$package_version" ] || fail "VERSION is empty"

printf 'Building knowledge-sdk %s...\n' "$package_version"
(cd "$source_root" && gem build knowledge-sdk.gemspec >/dev/null) || \
  fail "gem build failed"
gem_path=$source_root/knowledge-sdk-$package_version.gem
[ -f "$gem_path" ] || fail "expected package was not created: $gem_path"

if [ "$install_mode" = auto ]; then
  gem_home=$(gem environment gemdir)
  if [ -d "$gem_home" ] && [ -w "$gem_home" ]; then
    install_mode=system
  else
    install_mode=user
  fi
fi

printf 'Installing knowledge-sdk %s (%s install)...\n' "$package_version" "$install_mode"
if [ "$install_mode" = user ]; then
  gem install --user-install --no-document "$gem_path" || fail "gem install failed"
  executable_directory=$(ruby -rrubygems -e 'print File.join(Gem.user_dir, "bin")')
else
  gem install --no-document "$gem_path" || \
    fail "gem install failed; rerun with --user if the gem directory is not writable"
  executable_directory=$(ruby -rrubygems -e 'print Gem.bindir')
fi

kg_executable=$executable_directory/kg
if [ -x "$kg_executable" ]; then
  "$kg_executable" version >/dev/null || fail "kg was installed but its version check failed"
elif command -v kg >/dev/null 2>&1; then
  kg version >/dev/null || fail "kg was installed but its version check failed"
else
  fail "the gem was installed but the kg executable could not be found"
fi

printf '\nknowledge-sdk %s installed successfully.\n' "$package_version"
case ":${PATH}:" in
  *":${executable_directory}:"*) ;;
  *)
    printf 'Add this directory to PATH to run kg from any shell:\n  %s\n' "$executable_directory"
    ;;
esac
printf 'Try: kg version\n'
