#!/bin/sh

set -eu

repository_ref=${KNOWLEDGE_SDK_REF:-main}
install_mode=${KNOWLEDGE_SDK_INSTALL_MODE:-auto}
installer_url=${KNOWLEDGE_SDK_INSTALLER_URL:-https://raw.githubusercontent.com/rozdol/knowledge-sdk/main/install.sh}

usage() {
  cat <<'EOF'
Update an installed knowledge-sdk from its public Git repository.

Usage: update.sh [options]

Options:
  --ref REF       Update from a branch, tag, or commit (default: main)
  --user          Install into the current user's RubyGems directory
  --system        Install into the active RubyGems directory
  -h, --help      Show this help

Environment:
  KNOWLEDGE_SDK_INSTALLER_URL  Override the public install.sh URL
  KNOWLEDGE_SDK_REF            Override the Git ref
  KNOWLEDGE_SDK_INSTALL_MODE   Set auto, user, or system
EOF
}

fail() {
  printf 'knowledge-sdk updater: %s\n' "$*" >&2
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

for command_name in curl ruby; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is required"
done

installed_version() {
  ruby -rrubygems -e \
    'versions = Gem::Specification.find_all_by_name("knowledge-sdk").map(&:version); print versions.max if versions.any?'
}

current_version=$(installed_version)
[ -n "$current_version" ] || \
  fail "knowledge-sdk is not installed for the active Ruby; run install.sh first"

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/knowledge-sdk-update.XXXXXX") || \
  fail "could not create a temporary directory"
trap 'rm -rf "$temporary_root"' EXIT HUP INT TERM
installer_path=$temporary_root/install.sh

printf 'Current knowledge-sdk version: %s\n' "$current_version"
printf 'Fetching updater for %s...\n' "$repository_ref"
curl -fsSL "$installer_url" -o "$installer_path" || \
  fail "could not download installer from $installer_url"
sh -n "$installer_path" || fail "downloaded installer is not valid shell syntax"

case "$install_mode" in
  user) sh "$installer_path" --ref "$repository_ref" --user ;;
  system) sh "$installer_path" --ref "$repository_ref" --system ;;
  auto) sh "$installer_path" --ref "$repository_ref" ;;
esac

updated_version=$(installed_version)
[ -n "$updated_version" ] || fail "knowledge-sdk is unavailable after the update"
ruby -rrubygems -e \
  'exit Gem::Version.new(ARGV[1]) >= Gem::Version.new(ARGV[0]) ? 0 : 1' \
  "$current_version" "$updated_version" || \
  fail "installed version $updated_version is older than $current_version"

if [ "$updated_version" = "$current_version" ]; then
  printf '\nknowledge-sdk is already current at %s.\n' "$updated_version"
else
  printf '\nknowledge-sdk updated: %s -> %s.\n' "$current_version" "$updated_version"
fi
printf 'Try: kg version\n'
