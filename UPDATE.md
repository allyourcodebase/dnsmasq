# Update procedure

Bumping the upstream version involves:
1. Fetching the new version
2. Re-generating [generated.zig](generated.zig), the list of C sources, from the `objs` variable of upstream's `Makefile`
3. Bumping the package version in [build.zig.zon](build.zig.zon), which is also the version built into dnsmasq

[generate.zig](generate.zig) requires Zig `0.17`, as it is only run by maintainers.
It is run by the `generate` step of [build.zig](build.zig), which writes `generated.zig` in the source tree, and is not part of any other build: consumers do not need that Zig version, nor to parse upstream's `Makefile` themselves.

```shell
./update.sh 2.94
```

Then run `zig build test`.

## OpenTelemetry patches

The `opentelemetry` dependency is pinned to the commit of [opentelemetry-zig#122](https://github.com/open-telemetry/opentelemetry-zig/pull/122), from a fork, until it is merged: dnsmasq's counters are observable counters, which the SDK's main adds up on each export.
Then run `zig fetch --save=opentelemetry git+https://github.com/open-telemetry/opentelemetry-zig#<commit>`, and put `.lazy = true` back.

With `-Dotel`, a few lines are inserted next to given lines of `dnsmasq.c`, `forward.c` and `log.c`, by `patch.zig`: see `otel_patches` in `build.zig`.
If a new release changes or duplicates one of those lines, `zig build -Dotel` fails saying which: move the insertion to where the line went.
Check the hooks still make sense (a `-Dotel` build and `zig build test -Dotel` are not enough), for example against a collector and a dnsmasq upstream.

## Why a tarball and not `git+https`?

Upstream's git server only speaks version 0 of the git protocol, which Zig cannot fetch from, and the mirrors on GitHub lag behind the releases.
