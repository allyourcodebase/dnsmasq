const std = @import("std");
const builtin = @import("builtin");
const zon = @import("build.zig.zon");
const gen = @import("generated.zig");

const Build = std.Build;

/// A feature that upstream enables by default, and turns off with a `NO_*` macro.
const Feature = struct {
    option: []const u8,
    description: []const u8,
    no_macro: []const u8,
};

const features = [_]Feature{
    .{ .option = "dhcp", .description = "the DHCPv4 server (disabling it also disables DHCPv6)", .no_macro = "NO_DHCP" },
    .{ .option = "dhcp6", .description = "the DHCPv6 server and router advertisements", .no_macro = "NO_DHCP6" },
    .{ .option = "tftp", .description = "the TFTP server", .no_macro = "NO_TFTP" },
    .{ .option = "script", .description = "calling a script on DHCP lease changes", .no_macro = "NO_SCRIPT" },
    .{ .option = "auth", .description = "the authoritative DNS mode", .no_macro = "NO_AUTH" },
    .{ .option = "ipset", .description = "adding resolved addresses to ipsets (Linux and BSD only)", .no_macro = "NO_IPSET" },
    .{ .option = "loop", .description = "forwarding loop detection", .no_macro = "NO_LOOP" },
    .{ .option = "dumpfile", .description = "dumping packets to a pcap file", .no_macro = "NO_DUMPFILE" },
    .{ .option = "inotify", .description = "watching configuration files with inotify (Linux and FreeBSD 15 or later only)", .no_macro = "NO_INOTIFY" },
    .{ .option = "id", .description = "answering the id.server, version.bind, etc. CHAOS queries", .no_macro = "NO_ID" },
};

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Omit debug information");
    const pic = b.option(bool, "pic", "Produce Position Independent Code. Defaults to the target's default");
    const broken_rtc = b.option(
        bool,
        "broken_rtc",
        "For systems without a real-time clock keeping time across reboots: use uptime, and store lease lengths instead of expiry times. Defaults to false",
    ) orelse false;

    const otel = b.option(
        bool,
        "otel",
        "Export metrics and logs with OpenTelemetry (OTLP over HTTP, to localhost:4318 unless the OTEL_* environment variables say otherwise). Patches dnsmasq. Needs Zig 0.17 or later. Defaults to false",
    ) orelse false;

    var enabled: [features.len]bool = undefined;
    inline for (features, &enabled) |feature, *flag| {
        flag.* = b.option(bool, feature.option, "Enable " ++ feature.description ++ ". Defaults to true") orelse true;
    }

    // dnsmasq selects its networking code from the OS, and has no fallback.
    // Only the operating systems Zig can provide a libc for are listed
    switch (target.result.os.tag) {
        .linux, .macos, .freebsd, .netbsd, .openbsd => {},
        else => |os| {
            const fail = b.addFail(b.fmt("dnsmasq does not support the {t} operating system", .{os}));
            b.getInstallStep().dependOn(&fail.step);
            return;
        },
    }

    const upstream = b.dependency("upstream", .{});

    // For maintainers, not part of any build: update the list of sources, see UPDATE.md
    const generate_step = b.step("generate", "Update generated.zig with the C sources listed in upstream's Makefile");
    const generate = b.addExecutable(.{
        .name = "generate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("generate.zig"),
            .target = b.graph.host,
        }),
    });
    const run_generate = b.addRunArtifact(generate);
    run_generate.setStdIn(.{ .lazy_path = upstream.path("Makefile") });
    const update_generated = b.addUpdateSourceFiles();
    update_generated.addCopyFileToSource(run_generate.captureStdOut(.{}), "generated.zig");
    generate_step.dependOn(&update_generated.step);

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
        .pic = pic,
    });
    // Upstream relies on undefined behavior, which Zig turns into a crash in Debug and ReleaseSafe:
    // it casts the address of a `struct sockaddr_in`'s field to a `union all_addr *`, which is more aligned
    const flags: []const []const u8 = &.{"-fno-sanitize=undefined"};

    // The sources the OpenTelemetry hooks go into are patched copies
    var sources: std.ArrayList([]const u8) = .empty;
    inline for (gen.sources) |source| {
        if (!otel or !isPatched(source)) sources.append(b.allocator, source) catch @panic("OOM");
    }
    mod.addCSourceFiles(.{ .root = upstream.path("src"), .files = sources.items, .flags = flags });
    mod.addCMacro("VERSION", b.fmt("\"{s}\"", .{upstreamVersion()}));

    if (otel and !addOpenTelemetry(b, mod, upstream, target, optimize, strip, flags)) return;

    inline for (features, enabled) |feature, flag| {
        if (!flag) mod.addCMacro(feature.no_macro, "1");
    }
    if (broken_rtc) mod.addCMacro("HAVE_BROKEN_RTC", "1");

    const exe = b.addExecutable(.{
        .name = "dnsmasq",
        .root_module = mod,
    });
    b.installArtifact(exe);

    const man = b.addInstallFile(upstream.path("man/dnsmasq.8"), "share/man/man8/dnsmasq.8");
    b.getInstallStep().dependOn(&man.step);

    // Smoke tests
    const test_step = b.step("test", "Run smoke tests on the dnsmasq executable");

    const version = b.addRunArtifact(exe);
    version.addArg("--version");
    version.expectStdOutMatch(b.fmt("Dnsmasq version {s}", .{upstreamVersion()}));
    test_step.dependOn(&version.step);

    const example = b.addRunArtifact(exe);
    example.addArgs(&.{ "--test", "-C" });
    example.addFileArg(upstream.path("dnsmasq.conf.example"));
    example.expectStdErrEqual("dnsmasq: syntax check OK.\n");
    test_step.dependOn(&example.step);

    // A configuration using every enabled feature that has a directive to parse
    var config: std.ArrayList(u8) = .empty;
    config.appendSlice(b.allocator,
        \\address=/example.test/10.0.0.1
        \\server=/corp.test/192.0.2.53
        \\cname=www.example.test,example.test
        \\txt-record=example.test,"hello"
        \\cache-size=1000
        \\
    ) catch @panic("OOM");
    if (enabled[featureIndex("dhcp")]) config.appendSlice(b.allocator,
        \\dhcp-range=10.0.0.50,10.0.0.150,12h
        \\dhcp-host=aa:bb:cc:dd:ee:ff,printer,10.0.0.10
        \\dhcp-option=option:router,10.0.0.1
        \\
    ) catch @panic("OOM");
    if (enabled[featureIndex("dhcp")] and enabled[featureIndex("dhcp6")]) config.appendSlice(b.allocator,
        \\dhcp-range=fd00::10,fd00::ff,64,12h
        \\enable-ra
        \\
    ) catch @panic("OOM");
    if (enabled[featureIndex("tftp")]) config.appendSlice(b.allocator,
        \\enable-tftp
        \\tftp-root=/tmp
        \\
    ) catch @panic("OOM");
    if (enabled[featureIndex("auth")]) config.appendSlice(b.allocator,
        \\auth-server=ns.example.test,eth0
        \\auth-zone=example.test
        \\
    ) catch @panic("OOM");
    const config_file = b.addWriteFiles().add("dnsmasq.conf", config.items);

    const features_test = b.addRunArtifact(exe);
    features_test.addArgs(&.{ "--test", "-C" });
    features_test.addFileArg(config_file);
    features_test.expectStdErrEqual("dnsmasq: syntax check OK.\n");
    test_step.dependOn(&features_test.step);
}

/// Where the OpenTelemetry hooks go into upstream's sources: next to the one line which is `line`, once its whitespace is trimmed.
/// The build fails if upstream changed such that there isn't exactly one, see patch.zig.
const Edit = struct {
    where: enum { before, after },
    line: []const u8,
    text: []const u8,
};

const Patch = struct {
    file: []const u8,
    edits: []const Edit,
};

const include_otel: Edit = .{ .where = .after, .line = "#include \"dnsmasq.h\"", .text = "#include \"otel.h\"" };

const otel_patches = [_]Patch{
    .{
        .file = "dnsmasq.c",
        .edits = &.{
            include_otel,
            // Once running, and so forked and with its privileges dropped: the SDK has threads, which do not survive a fork
            .{ .where = .before, .line = "/* finished start-up - release original process */", .text = "  dnsmasq_otel_init();\n" },
            .{ .where = .after, .line = "int timeout = fast_retry(now);", .text = "      dnsmasq_otel_poll();" },
        },
    },
    .{ .file = "forward.c", .edits = &.{
        include_otel,
        .{
            .where = .after,
            .line = "server->query_latency = server->mma_latency/128;",
            .text = "  dnsmasq_otel_upstream_reply(server, dnsmasq_milliseconds() - forward->forward_timestamp);",
        },
    } },
    .{ .file = "log.c", .edits = &.{
        include_otel,
        .{
            .where = .before,
            .line = "if (echo_stderr)",
            .text = "  va_start(ap, format);\n  dnsmasq_otel_log(priority, func, format, ap);\n  va_end(ap);\n",
        },
    } },
};

fn isPatched(source: []const u8) bool {
    for (otel_patches) |patch| {
        if (std.mem.eql(u8, patch.file, source)) return true;
    }
    return false;
}

fn addOpenTelemetry(
    b: *Build,
    mod: *Build.Module,
    upstream: *Build.Dependency,
    target: Build.ResolvedTarget,
    optimize: anytype,
    strip: ?bool,
    flags: []const []const u8,
) bool {
    if (comptime builtin.zig_version.order(.{ .major = 0, .minor = 17, .patch = 0 }) == .lt) {
        const fail = b.addFail("-Dotel needs Zig 0.17 or later, which the OpenTelemetry SDK requires");
        b.getInstallStep().dependOn(&fail.step);
        return false;
    }

    // A lazy dependency: only those who ask for OpenTelemetry fetch it
    const sdk = b.lazyDependency("opentelemetry", .{
        .target = target,
        // The SDK only has a choice of safe or not, whatever ours is
        .release = optimize != .debug,
    }) orelse return true;

    const patch = b.addExecutable(.{
        .name = "patch",
        .root_module = b.createModule(.{
            .root_source_file = b.path("patch.zig"),
            .target = b.graph.host,
        }),
    });
    for (otel_patches) |patched| {
        const run = b.addRunArtifact(patch);
        run.addFileArg(upstream.path(b.fmt("src/{s}", .{patched.file})));
        const output = run.addOutputFileArg(patched.file);
        for (patched.edits) |edit| run.addArgs(&.{ if (edit.where == .before) "--before" else "--after", edit.line, edit.text });
        mod.addCSourceFile(.{ .file = output, .flags = flags });
    }
    // The patched copies are elsewhere than the headers they include
    mod.addIncludePath(upstream.path("src"));
    mod.addIncludePath(b.path("otel"));
    mod.addCSourceFile(.{ .file = b.path("otel/glue.c") });

    const options = b.addOptions();
    options.addOption([]const u8, "version", upstreamVersion());
    const hooks = b.addLibrary(.{
        .name = "dnsmasq-otel",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("otel/otel.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .strip = strip,
            .imports = &.{
                .{ .name = "opentelemetry-sdk", .module = sdk.module("sdk") },
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
    });
    mod.linkLibrary(hooks);
    return true;
}

/// The version of dnsmasq, which is the package's one without the patch number (upstream's are `major.minor`)
fn upstreamVersion() []const u8 {
    const version = comptime std.SemanticVersion.parse(zon.version) catch unreachable;
    std.debug.assert(version.patch == 0);
    return std.fmt.comptimePrint("{d}.{d}", .{ version.major, version.minor });
}

fn featureIndex(comptime option: []const u8) usize {
    inline for (features, 0..) |feature, i| {
        if (comptime std.mem.eql(u8, feature.option, option)) return i;
    }
    @compileError("unknown feature " ++ option);
}
