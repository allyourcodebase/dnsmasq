const std = @import("std");
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
    mod.addCSourceFiles(.{
        .root = upstream.path("src"),
        .files = &gen.sources,
        // Upstream relies on undefined behavior, which Zig turns into a crash in Debug and ReleaseSafe:
        // it casts the address of a `struct sockaddr_in`'s field to a `union all_addr *`, which is more aligned
        .flags = &.{"-fno-sanitize=undefined"},
    });
    mod.addCMacro("VERSION", b.fmt("\"{s}\"", .{upstreamVersion()}));

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
