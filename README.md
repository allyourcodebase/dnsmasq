# dnsmasq packaged for the Zig build system

This is [dnsmasq](https://thekelleys.org.uk/dnsmasq/doc.html), a lightweight DNS forwarder, DHCP, TFTP and router advertisement server, packaged for [Zig](https://ziglang.org/).
It builds the `dnsmasq` executable from the upstream release, so that it can be cross-compiled and used from other Zig projects, for example to run it in their tests.

## Status

| Architecture \ OS | Linux | macOS | FreeBSD | NetBSD | OpenBSD |
|:------------------|:-----:|:-----:|:-------:|:------:|:-------:|
| x86_64            | ✅    | ?     | ✅      | ✅     | ✅      |
| arm 64            | ✅    | ✅    | ✅      | ✅     | ✅      |

Also builds for Linux on `arm`, `x86`, `riscv64`, `powerpc64le`, `s390x` and `loongarch64`, with both glibc and musl.

| Refname          | dnsmasq version | Zig `0.18-dev` | Zig `0.17.x` | Zig `0.16.x` |
|:-----------------|:----------------|:--------------:|:------------:|:------------:|
| `master`, `2.93` | `v2.93`         | ✅             | ✅           | ✅           |

## Install

Clone this repository, and install to a prefix of your choice, for example `~/.local`:
```shell
zig build -p ~/.local -Doptimize=ReleaseSafe -Dstrip=true
```

This installs `dnsmasq` in `~/.local/bin`, and its manual page in `~/.local/share/man/man8`.
The prefix defaults to `zig-out`.
Zig downloads the dnsmasq sources itself: there is nothing else to install.

To build for another machine, add `-Dtarget` and copy the prefix over, for example `-Dtarget=aarch64-linux-musl` for a statically linked executable that runs on any 64-bit ARM Linux.
Zig can only target macOS from a Mac, and only for the Mac itself: see [Limitations](#macos).

Options are given the same way, for example `-Dtftp=false` to leave the TFTP server out: see [Options](#options).

## Use as a dependency

Add the dependency to your `build.zig.zon` by running the following command:
```shell
zig fetch --save git+https://github.com/allyourcodebase/dnsmasq#master
```

Then, from your `build.zig`, get the executable to install it, or to run it:
```zig
const dnsmasq = b.dependency("dnsmasq", .{
    .target = target,
    .optimize = optimize,
});

b.installArtifact(dnsmasq.artifact("dnsmasq"));

const run = b.addRunArtifact(dnsmasq.artifact("dnsmasq"));
run.addArgs(&.{ "--keep-in-foreground", "--port=5353" });
```

`zig build test` runs smoke tests: the version it reports, and that it accepts both upstream's example configuration and one using the enabled features.

## Options

```
  -Dstrip=[bool]               Omit debug information
  -Dpic=[bool]                 Produce Position Independent Code. Defaults to the target's default
  -Dbroken_rtc=[bool]          For systems without a real-time clock keeping time across reboots: use uptime, and store lease lengths instead of expiry times. Defaults to false
  -Dotel=[bool]                Export metrics and logs with OpenTelemetry (OTLP over HTTP, to localhost:4318 unless the OTEL_* environment variables say otherwise). Patches dnsmasq. Needs Zig 0.17 or later. Defaults to false
  -Ddhcp=[bool]                Enable the DHCPv4 server (disabling it also disables DHCPv6). Defaults to true
  -Ddhcp6=[bool]               Enable the DHCPv6 server and router advertisements. Defaults to true
  -Dtftp=[bool]                Enable the TFTP server. Defaults to true
  -Dscript=[bool]              Enable calling a script on DHCP lease changes. Defaults to true
  -Dauth=[bool]                Enable the authoritative DNS mode. Defaults to true
  -Dipset=[bool]               Enable adding resolved addresses to ipsets (Linux and BSD only). Defaults to true
  -Dloop=[bool]                Enable forwarding loop detection. Defaults to true
  -Ddumpfile=[bool]            Enable dumping packets to a pcap file. Defaults to true
  -Dinotify=[bool]             Enable watching configuration files with inotify (Linux and FreeBSD 15 or later only). Defaults to true
  -Did=[bool]                  Enable answering the id.server, version.bind, etc. CHAOS queries. Defaults to true
```

These map to the `NO_*` compile-time options of upstream's `config.h`, and the defaults are upstream's.

## OpenTelemetry

Experimental: `-Dotel=true` builds dnsmasq with hooks which export its metrics and logs to a collector, with [opentelemetry-zig](https://github.com/open-telemetry/opentelemetry-zig), an alpha SDK.
It needs Zig 0.17 or later, which is also the only case in which the SDK is fetched, and it adds about 1.8 MB: 0.5 MB become 2.3 MB for an `x86_64-linux-musl` build in `ReleaseSafe`, stripped.
Three of upstream's files are patched, see [`UPDATE.md`](UPDATE.md).

```shell
zig build -p ~/.local -Doptimize=ReleaseSafe -Dstrip=true -Dotel=true
OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318 ~/.local/bin/dnsmasq --keep-in-foreground
```

Data is sent with OTLP over HTTP, to a collector on the same machine unless told otherwise: `127.0.0.1:4318`, an address rather than `localhost` so that exporting never needs a lookup by dnsmasq itself.
The standard variables select another one: `OTEL_EXPORTER_OTLP_ENDPOINT` and `OTEL_EXPORTER_OTLP_PROTOCOL` (`http/protobuf` or `http/json`: gRPC is not built), `OTEL_SERVICE_NAME` (`dnsmasq`), `OTEL_RESOURCE_ATTRIBUTES`, and `OTEL_METRIC_EXPORT_INTERVAL` (here 1 second rather than 60, which is also the resolution of the metrics, and the SDK keeps every measurement until it exports them: the longer, the more memory).
The collector can batch the points before sending them on, for example with its `batch` processor, without losing that resolution.

| Name | Kind | What |
|:-----|:-----|:-----|
| `dnsmasq.<counter>` | cumulative counter | Each of dnsmasq's own counters, reported as they are, once it is not zero: `dns_queries_forwarded`, `dns_local_answered`, `dns_auth_answered`, `dns_cache_inserted`, `dhcp_ack`, ... |
| `dnsmasq.tcp_connections` | gauge | How many processes are serving TCP queries now |
| `dnsmasq.server.queries`, `.failed_queries`, `.nxdomain_replies`, `.retries` | cumulative counter | The same for each upstream server, as `server.address`. A server which goes away keeps its last values |
| `dnsmasq.query.duration` | histogram, ms | The time from a query arriving to its reply being sent, by `dnsmasq.answer`: `local` when dnsmasq answers (from its cache, its hosts, an `--address`, or with an error) and `upstream` when it waited for a server, retries included |
| `dnsmasq.upstream.duration` | histogram, ms | The time from sending a query to an upstream server to its reply, by `server.address`: the last attempt only, and none for a retry that was not answered. Both histograms have the same buckets, from 0.02 ms to 5 s |
| logs | | What dnsmasq logs, with its syslog priority as the severity (the number [OpenTelemetry maps it to](https://opentelemetry.io/docs/specs/otel/logs/data-model-appendix/#appendix-b-severitynumber-example-mappings), and its name as the text), and `dnsmasq.facility` (`dhcp`, `tftp`, `script` or `debug`, and none for DNS). Queries are only logged with `--log-queries` |

Counters are cumulative, as dnsmasq keeps them: rates, such as queries per second, and deltas are for the collector or the backend to compute.
Answers from the cache are not in `dnsmasq.upstream.duration`, as they do not wait for anyone, but they are in `dnsmasq.query.duration`.
The durations are measured by dnsmasq: from when it starts handling a query, not from when the packet reached the socket.

What is not exported:
- What dnsmasq logs while starting: the SDK starts once it runs, as it uses threads, which do not survive the forks of the daemonization.
- Queries over TCP, which a forked process answers, whose counters and logs are lost with it. Only the number of such processes is observed. With `--no-daemon`, there are no such forks.

## Limitations

### Optional dependencies

The features of dnsmasq which need an external library are not built: DNSSEC (nettle), D-Bus, ubus, IDN and IDN2, Lua scripts, conntrack and nftables sets.
Translations are not built either.

### macOS

Zig's bundled copy of the macOS headers lacks some networking ones dnsmasq needs (`netinet/ip6.h`), so the build relies on the Xcode SDK, which Zig only finds when building for the host.
Build without `-Dtarget`, or with only `-Dcpu`, `-Doptimize`, etc.
Explicitly targeting macOS, including from an Intel Mac for an ARM one, or cross-compiling to it from another OS, fails to compile.

### Undefined behavior

Upstream relies on undefined behavior (misaligned accesses, for one), which Zig's default sanitizer for C turns into a crash in Debug and ReleaseSafe builds.
It is disabled for dnsmasq's sources, as it is in upstream's own build.

### Other operating systems

Zig cannot provide a libc for DragonFly BSD or illumos, so they are not supported, nor are Windows and WASI, which dnsmasq does not support.

## License

The build scripts are [MIT](LICENSE) licensed. dnsmasq itself is licensed under the GPL, version 2 or 3: see its [`COPYING`](https://thekelleys.org.uk/gitweb/?p=dnsmasq.git;a=blob;f=COPYING).
