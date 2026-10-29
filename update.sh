#!/bin/bash
# Parameter: New dnsmasq version, as in its tarball's name, e.g. "2.94"
set -euo pipefail

VERSION=$1

# 1. Fetch the new version
zig fetch --save=upstream "https://thekelleys.org.uk/dnsmasq/dnsmasq-$VERSION.tar.xz"

# 2. Re-generate the file list
zig build generate

# 3. Bump the package version, which has to be a semantic one
sed "s|\([.]version *= *\).*|\1\"$VERSION.0\",|" build.zig.zon > tmp.zon
mv tmp.zon build.zig.zon
