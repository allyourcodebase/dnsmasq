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

## Why a tarball and not `git+https`?

Upstream's git server only speaks version 0 of the git protocol, which Zig cannot fetch from, and the mirrors on GitHub lag behind the releases.
