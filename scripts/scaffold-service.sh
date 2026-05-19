#!/usr/bin/env bash
#
# Scaffold a new hecate-services/hecate-X repo from the templates in
# this library.
#
# Usage:
#   scripts/scaffold-service.sh <target-dir> <service-name> "<one-line description>"
#
# Example:
#   scripts/scaffold-service.sh \
#     ~/work/codeberg.org/hecate-services/hecate-dns \
#     hecate-dns \
#     "DNS-over-Mesh name resolution for the Hecate realm"
#
# Idempotent on safe-to-overwrite files (templates render to a known
# fingerprint); refuses to overwrite README.md / LICENSE / src/*.erl
# if they already exist.

set -euo pipefail

TARGET="${1:?usage: scaffold-service.sh <target-dir> <service-name> <description>}"
SERVICE_NAME="${2:?service-name required, e.g. hecate-dns}"
DESCRIPTION="${3:?one-line description required}"

# Derive Erlang-style names. hecate-dns → hecate_dns → hecate_dns_service.
ERLANG_APP="${SERVICE_NAME//-/_}"
ERLANG_SERVICE_MOD="${ERLANG_APP}_service"
DISPLAY_NAME="${SERVICE_NAME#hecate-}"
DISPLAY_NAME="${DISPLAY_NAME^}"  # capitalise first letter

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES="$(cd "$HERE/../templates" && pwd)"

mkdir -p "$TARGET"/{src,apps,quadlet,config,.github/workflows,test,guides,scripts}

render() {
    local in="$1" out="$2"
    sed \
        -e "s|{{service_name}}|${SERVICE_NAME}|g" \
        -e "s|{{erlang_app_name}}|${ERLANG_APP}|g" \
        -e "s|{{erlang_service_module}}|${ERLANG_SERVICE_MOD}|g" \
        -e "s|{{display_name}}|${DISPLAY_NAME}|g" \
        -e "s|{{description}}|${DESCRIPTION}|g" \
        < "$in" > "$out"
    echo "  rendered $(basename "$out")"
}

render "$TEMPLATES/Containerfile.tmpl"       "$TARGET/Containerfile"
render "$TEMPLATES/quadlet.container.tmpl"   "$TARGET/quadlet/${SERVICE_NAME}.container"
render "$TEMPLATES/manifest.json.tmpl"       "$TARGET/manifest.json"
render "$TEMPLATES/ci-build-push.yml.tmpl"   "$TARGET/.github/workflows/build-push.yml"
render "$TEMPLATES/_app.erl.tmpl"            "$TARGET/src/${ERLANG_APP}_app.erl"
render "$TEMPLATES/_service.erl.tmpl"        "$TARGET/src/${ERLANG_SERVICE_MOD}.erl"
render "$TEMPLATES/sys.config.src.tmpl"      "$TARGET/config/sys.config.src"

echo
echo "Service skeleton ready at $TARGET"
echo "Next: write src/${ERLANG_APP}.app.src, src/${ERLANG_APP}_sup.erl, rebar.config."
