#!/usr/bin/env bash
# Make `rebar3 new hecate_service' available on this machine.
#
# rebar3 discovers custom templates only in its global config directory, and
# only there when you are standing in an empty directory with no rebar.config,
# which is exactly the situation you are in when scaffolding a new service. So
# the templates cannot simply be carried by the hecate_om dependency: nothing
# has fetched it yet.
#
# THAT DIRECTORY IS NOT ALWAYS UNDER HOME. rebar3 takes it as
# <base>/.config/rebar3, where base is REBAR_GLOBAL_CONFIG_DIR, else
# REBAR_CACHE_DIR, else HOME. Installing under HOME while either variable is
# exported leaves `rebar3 new hecate_service' failing with "template not found".
# A variable set to the empty string still wins in rebar3 and then names a path
# relative to wherever rebar3 runs, so that is refused here rather than guessed.
#
# SYMLINKS RATHER THAN COPIES, so editing a template in this checkout takes
# effect immediately and there is one copy to keep right. That is the failure
# this whole thing is fixing: the previous templates drifted for months because
# nothing exercised them and nobody noticed.
#
# Usage:
#
#   scripts/install-templates.sh            # install or refresh
#   scripts/install-templates.sh --remove   # take them out again

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${REPO}/priv/templates"
for var in REBAR_GLOBAL_CONFIG_DIR REBAR_CACHE_DIR; do
    if [ -n "${!var+set}" ] && [ -z "${!var}" ]; then
        echo "${var} is set but empty; unset it or name a directory" >&2
        exit 1
    fi
done
DEST="${REBAR_GLOBAL_CONFIG_DIR-${REBAR_CACHE_DIR-${HOME}}}/.config/rebar3/templates"

if [ ! -d "${SRC}" ]; then
    echo "no templates at ${SRC}" >&2
    exit 1
fi

# One entry per template: the .template manifest and the directory of sources it
# names. Discovered rather than listed, so adding a second template needs no
# change here.
entries() {
    find "${SRC}" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort
}

remove() {
    local n
    while read -r n; do
        [ -L "${DEST}/${n}" ] || continue
        rm -f "${DEST}/${n}"
        echo "removed ${DEST}/${n}"
    done < <(entries)
}

install() {
    mkdir -p "${DEST}"
    local n
    while read -r n; do
        # A real file or directory that is not our symlink is somebody else's
        # template. Refuse rather than clobber it.
        if [ -e "${DEST}/${n}" ] && [ ! -L "${DEST}/${n}" ]; then
            echo "refusing to replace non-symlink ${DEST}/${n}" >&2
            exit 2
        fi
        ln -sfn "${SRC}/${n}" "${DEST}/${n}"
        echo "linked ${DEST}/${n} -> ${SRC}/${n}"
    done < <(entries)
}

case "${1:-}" in
    --remove) remove ;;
    "")       install
              echo
              echo "Now, from the directory that will hold the new repository:"
              echo
              echo "  rebar3 new hecate_service repo=hecate-foo name=hecate_foo \\"
              echo "      desc=\"Does X over the mesh\" health_port=8484"
              ;;
    *)        echo "usage: $0 [--remove]" >&2 ; exit 64 ;;
esac
