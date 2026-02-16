#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SRC_DIR="$ROOT_DIR/src"
DIST_DIR="$ROOT_DIR/dist"
PKG_NAME="zabbix-agent2-plugin-docker-swarm"
UPLOAD_URL="https://repomanager.mke.clearlyip.net/api/v2/snapshot/25/upload"
REBUILD_URL="https://repomanager.mke.clearlyip.net/api/v2/snapshot/25/rebuild"

usage() {
	cat <<'USAGE'
Usage: scripts/build-deb.sh [--arch <amd64|arm64>] [--no-upload]

Build a Debian package for the Zabbix Docker Swarm plugin and upload it to
RepoManager. The API key is loaded from ~/.repomanager using RM_API_KEY.
USAGE
}

ARCH=""
UPLOAD=1

while [ "$#" -gt 0 ]; do
	case "$1" in
		--arch)
			ARCH="$2"
			shift 2
			;;
		--no-upload)
			UPLOAD=0
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			echo "Unknown argument: $1" >&2
			usage >&2
			exit 1
			;;
	esac

done

if [ -z "$ARCH" ]; then
	if command -v dpkg >/dev/null 2>&1; then
		ARCH=$(dpkg --print-architecture)
	else
		case "$(uname -m)" in
			x86_64)
				ARCH="amd64"
				;;
			aarch64|arm64)
				ARCH="arm64"
				;;
			*)
				echo "Unable to determine architecture; use --arch." >&2
				exit 1
				;;
		esac
	fi
fi

case "$ARCH" in
	amd64|x86_64)
		DEB_ARCH="amd64"
		MAKE_TARGET="build-x86_64"
		BIN_NAME="docker-swarm-linux-x86_64"
		;;
	arm64|aarch64)
		DEB_ARCH="arm64"
		MAKE_TARGET="build-arm64"
		BIN_NAME="docker-swarm-linux-arm64"
		;;
	*)
		echo "Unsupported architecture: $ARCH" >&2
		exit 1
		;;
esac

if ! command -v dpkg-deb >/dev/null 2>&1; then
	echo "dpkg-deb is required to build the package." >&2
	exit 1
fi

VERSION_MAJOR=$(grep "PLUGIN_VERSION_MAJOR" "$SRC_DIR/main.go" | awk '{print $3}')
VERSION_MINOR=$(grep "PLUGIN_VERSION_MINOR" "$SRC_DIR/main.go" | awk '{print $3}')
VERSION_PATCH=$(grep "PLUGIN_VERSION_PATCH" "$SRC_DIR/main.go" | awk '{print $3}')
VERSION_RC=$(grep "PLUGIN_VERSION_RC" "$SRC_DIR/main.go" | awk -F'"' '{print $2}')

VERSION="${VERSION_MAJOR}.${VERSION_MINOR}.${VERSION_PATCH}"
if [ -n "$VERSION_RC" ]; then
	VERSION="${VERSION}~${VERSION_RC}"
fi

(
	cd "$SRC_DIR"
	make "$MAKE_TARGET"
)

BIN_PATH="$SRC_DIR/$BIN_NAME"
if [ ! -f "$BIN_PATH" ]; then
	echo "Expected binary not found: $BIN_PATH" >&2
	exit 1
fi

PKG_ROOT="$DIST_DIR/deb/root"
rm -rf "$PKG_ROOT"
mkdir -p "$PKG_ROOT/DEBIAN" "$PKG_ROOT/var/lib/zabbix/plugins"

install -m 0755 "$BIN_PATH" "$PKG_ROOT/var/lib/zabbix/plugins/docker-swarm"

cat > "$PKG_ROOT/DEBIAN/control" <<EOCONTROL
Package: $PKG_NAME
Version: $VERSION
Section: net
Priority: optional
Architecture: $DEB_ARCH
Maintainer: Toon Toetenel <noreply@localhost>
Description: Zabbix Agent 2 Docker Swarm plugin
 Service-level monitoring plugin for Docker Swarm with stable discovery.
EOCONTROL

cat > "$PKG_ROOT/DEBIAN/postrm" <<'EOPOSTRM'
#!/bin/sh
set -e

case "$1" in
	remove|purge)
		mkdir -p /var/lib/zabbix/plugins
		;;
esac

exit 0
EOPOSTRM
chmod 0755 "$PKG_ROOT/DEBIAN/postrm"

mkdir -p "$DIST_DIR"
OUT_DEB="$DIST_DIR/${PKG_NAME}_${VERSION}_${DEB_ARCH}.deb"
dpkg-deb --build "$PKG_ROOT" "$OUT_DEB" >/dev/null

echo "Built Debian package: $OUT_DEB"

if [ "$UPLOAD" -eq 1 ]; then
	RM_API_FILE="${RM_API_FILE:-$HOME/.repomanager}"
	if [ -f "$RM_API_FILE" ]; then
		# shellcheck disable=SC1090
		. "$RM_API_FILE"
	fi

	if [ -z "${RM_API_KEY:-}" ]; then
		echo "RM_API_KEY not set. Add it to $RM_API_FILE or export it." >&2
		exit 1
	fi

	DEB_NAME=$(basename "$OUT_DEB")
	cp "$OUT_DEB" "/tmp/$DEB_NAME"

	curl -L --post301 -s -q -X POST \
		-H "Authorization: Bearer ${RM_API_KEY}" \
		-F "files=@/tmp/${DEB_NAME}" \
		"$UPLOAD_URL"

	curl -L -s -q -X PUT \
		-H "Authorization: Bearer ${RM_API_KEY}" \
		-H "Content-Type: application/json" \
		-d '{"gpgSign":"true"}' \
		"$REBUILD_URL"

	printf '\nUploaded to %s and rebuild triggered at %s\n' "$UPLOAD_URL" "$REBUILD_URL"
fi
