//! The OpenTelemetry side of the hooks in otel.h, enabled by -Dotel.
//!
//! Counters and the upstream latency are metrics, dnsmasq's log is exported as logs. They go to an OTLP collector,
//! by default over HTTP on the local machine: the standard OTEL_* environment variables select another one.
//!
//! dnsmasq's counters are reported as they are: cumulative and monotonic, which the metric declares, and what to do
//! about it is up to the collector and the backend. They are observed by the SDK when it exports, from its own thread,
//! and dnsmasq's thread says what they are worth: atomically, as dnsmasq's memory is not for another thread to read.
//!
//! The functions exported to C are called from dnsmasq's only thread, apart from the SDK's own threads which export in the background.

const std = @import("std");
const sdk = @import("opentelemetry-sdk");
const build_options = @import("build_options");

const allocator = std.heap.c_allocator;

/// An address, rather than a name: looking one up could end up asking dnsmasq itself, from its only thread.
const default_endpoint = "127.0.0.1:4318";

/// A short interval: the SDK keeps every measurement until it exports, rather than aggregating them as they come.
const default_export_interval_ms = "10000";

const Histogram = sdk.metrics.Histogram(f64);

var threaded: std.Io.Threaded = undefined;
var env: std.process.Environ.Map = undefined;
var otlp_config: *sdk.otlp.ConfigOptions = undefined;

var meter_provider: *sdk.metrics.MeterProvider = undefined;
var metric_reader: *sdk.metrics.PeriodicExportingReader = undefined;
var addresses: std.StringHashMapUnmanaged(void) = .empty;
var io: std.Io = undefined;

// The SDK does not export the types of a meter and of its observable instruments: they are the ones of its functions
const Meter = @typeInfo(@typeInfo(@TypeOf(sdk.metrics.MeterProvider.getMeter)).@"fn".return_type.?).error_union.payload;
const create_observable_counter = @typeInfo(@TypeOf(@typeInfo(Meter).pointer.child.createObservableCounter)).@"fn";
const ObservedContext = create_observable_counter.param_types[2].?;
const ObserveMeasures = @typeInfo(@typeInfo(create_observable_counter.param_types[3].?).optional.child).pointer.child;
const ObserveResult = @typeInfo(@typeInfo(ObserveMeasures).pointer.child).@"fn".return_type.?;
const MeasurementsData = @typeInfo(ObserveResult).error_union.payload;
const DataPoint = @typeInfo(@FieldType(MeasurementsData, "int")).pointer.child;

var meter: Meter = undefined;
var upstream_latency: *Histogram = undefined;

/// What one of dnsmasq's values was worth when it last said
const Observed = struct { value: std.atomic.Value(u64) };
var observed: std.StringHashMapUnmanaged(*Observed) = .empty;

/// The counters of dnsmasq for an upstream server. They are observed together, by their position
const server_counter_names = [_][]const u8{ "queries", "failed_queries", "nxdomain_replies", "retries" };
var server_counter_positions = [_]usize{ 0, 1, 2, 3 };
const Server = struct { address: []const u8, values: [server_counter_names.len]std.atomic.Value(u64) };
/// Only dnsmasq's thread adds to it, and the SDK's reads it
var servers: std.ArrayList(*Server) = .empty;
var servers_lock: std.Io.Mutex = .init;

var logger_provider: *sdk.logs.LoggerProvider = undefined;
var log_processor: *sdk.logs.BatchingLogRecordProcessor = undefined;
var logger: *sdk.logs.Logger = undefined;

comptime {
    @export(&start, .{ .name = "otel_start" });
    @export(&stop, .{ .name = "otel_stop" });
    @export(&observeCounter, .{ .name = "otel_observe_counter" });
    @export(&observeGauge, .{ .name = "otel_observe_gauge" });
    @export(&observeServer, .{ .name = "otel_observe_server" });
    @export(&recordUpstreamLatency, .{ .name = "otel_record_upstream_latency" });
    @export(&log, .{ .name = "otel_log" });
}

fn start() callconv(.c) c_int {
    startSdk() catch |err| {
        std.log.err("cannot start OpenTelemetry: {t}", .{err});
        return -1;
    };
    return 0;
}

fn startSdk() !void {
    threaded = .init(allocator, .{});
    io = threaded.io();

    // The standard OTEL_* variables configure the SDK, they are the only ones of interest
    env = .init(allocator);
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        const variable = std.mem.span(entry);
        const equals = std.mem.indexOfScalar(u8, variable, '=') orelse continue;
        if (std.mem.startsWith(u8, variable, "OTEL_"))
            try env.put(variable[0..equals], variable[equals + 1 ..]);
    }
    if (env.get("OTEL_SERVICE_NAME") == null)
        try env.put("OTEL_SERVICE_NAME", "dnsmasq");
    if (env.get("OTEL_RESOURCE_ATTRIBUTES") == null)
        try env.put("OTEL_RESOURCE_ATTRIBUTES", "service.version=" ++ build_options.version);
    if (env.get("OTEL_METRIC_EXPORT_INTERVAL") == null)
        try env.put("OTEL_METRIC_EXPORT_INTERVAL", default_export_interval_ms);

    const sdk_config = try sdk.config.init(allocator, io, &env);
    sdk.config.set(sdk_config);

    otlp_config = try sdk.otlp.ConfigOptions.init(allocator, &env);
    // Unless set from the environment, the endpoint is not allocated and can be replaced
    if (env.get("OTEL_EXPORTER_OTLP_ENDPOINT") == null)
        otlp_config.endpoint = default_endpoint;

    // Metrics
    meter_provider = try sdk.metrics.MeterProvider.init(allocator, io);
    const metric_exporter = try sdk.metrics.MetricExporter.OTLP(allocator, io, null, null, otlp_config);
    metric_reader = try sdk.metrics.PeriodicExportingReader.init(
        allocator,
        io,
        meter_provider,
        metric_exporter.exporter,
        sdk_config.metrics_config.export_interval_ms,
        sdk_config.metrics_config.export_timeout_ms,
    );
    meter = try meter_provider.getMeter(.{ .name = "dnsmasq", .version = build_options.version });
    upstream_latency = try meter.createHistogram(f64, .{
        .name = "dnsmasq.upstream.duration",
        .description = "Time between forwarding a query to an upstream server and its reply",
        .unit = "ms",
    });
    inline for (server_counter_names, 0..) |name, position| {
        const instrument = try meter.createObservableCounter(
            .{ .name = "dnsmasq.server." ++ name },
            ObservedContext.from(&server_counter_positions[position]),
            null,
        );
        try instrument.registerCallback(observeServers);
    }

    // Logs, batched: the event loop must not wait for the collector
    const log_exporter = try sdk.logs.OTLPExporter.init(allocator, io, otlp_config);
    log_processor = try sdk.logs.BatchingLogRecordProcessor.init(allocator, io, log_exporter.asLogRecordExporter(), .{});
    logger_provider = try sdk.logs.LoggerProvider.init(allocator, io, null);
    try logger_provider.addLogRecordProcessor(log_processor.asLogRecordProcessor());
    logger = try logger_provider.getLogger(.{ .name = "dnsmasq", .version = build_options.version });
}

/// Export what is pending, and stop the threads
fn stop() callconv(.c) void {
    metric_reader.shutdown();
    meter_provider.shutdown();
    logger_provider.shutdown() catch {};
}

/// A copy of an address which lasts: the SDK keeps the attributes' values, not copies of them, until it exports.
/// There is one per upstream server.
fn intern(address: []const u8) ?[]const u8 {
    if (addresses.getKey(address)) |existing| return existing;

    const owned = allocator.dupe(u8, address) catch return null;
    addresses.put(allocator, owned, {}) catch {
        allocator.free(owned);
        return null;
    };
    return owned;
}

fn clamp(value: u64) i64 {
    return @intCast(@min(value, std.math.maxInt(i64)));
}

fn observeValue(context: ObservedContext, gpa: std.mem.Allocator) ObserveResult {
    const value = context.into(Observed).?;
    const points = try gpa.alloc(DataPoint, 1);
    errdefer gpa.free(points);
    points[0] = try DataPoint.new(gpa, clamp(value.value.load(.monotonic)), .{});
    return .{ .int = points };
}

fn observeServers(context: ObservedContext, gpa: std.mem.Allocator) ObserveResult {
    const position = context.into(usize).?.*;

    servers_lock.lockUncancelable(io);
    defer servers_lock.unlock(io);

    const points = try gpa.alloc(DataPoint, servers.items.len);
    var made: usize = 0;
    errdefer {
        for (points[0..made]) |*point| point.deinit(gpa);
        gpa.free(points);
    }
    for (servers.items) |server| {
        points[made] = try DataPoint.new(gpa, clamp(server.values[position].load(.monotonic)), .{ "server.address", server.address });
        made += 1;
    }
    return .{ .int = points };
}

/// The instrument of that name, created when it is first observed.
/// The name is kept: the SDK does not copy it.
fn createObserved(comptime kind: enum { counter, gauge }, name: []const u8, value: u64) !*Observed {
    const owned = try allocator.dupe(u8, name);
    errdefer allocator.free(owned);
    const created = try allocator.create(Observed);
    errdefer allocator.destroy(created);
    created.* = .{ .value = .init(value) };

    const instrument = switch (kind) {
        .counter => try meter.createObservableCounter(.{ .name = owned }, ObservedContext.from(created), null),
        .gauge => try meter.createObservableGauge(.{ .name = owned }, ObservedContext.from(created), null),
    };
    try instrument.registerCallback(observeValue);
    try observed.put(allocator, owned, created);
    return created;
}

/// A counter, which only goes up. There is none until it is not zero, so that there is none for what dnsmasq never does.
fn observeCounter(name: [*:0]const u8, value: u64) callconv(.c) void {
    if (observed.get(std.mem.span(name))) |known| {
        known.value.store(value, .monotonic);
    } else if (value != 0) {
        _ = createObserved(.counter, std.mem.span(name), value) catch {};
    }
}

/// A value which goes up and down. Zero is an observation too.
fn observeGauge(name: [*:0]const u8, value: u64) callconv(.c) void {
    if (observed.get(std.mem.span(name))) |known| {
        known.value.store(value, .monotonic);
    } else {
        _ = createObserved(.gauge, std.mem.span(name), value) catch {};
    }
}

fn createServer(address: []const u8) !*Server {
    const interned = intern(address) orelse return error.OutOfMemory;
    const server = try allocator.create(Server);
    errdefer allocator.destroy(server);
    server.* = .{ .address = interned, .values = @splat(.init(0)) };

    servers_lock.lockUncancelable(io);
    defer servers_lock.unlock(io);
    try servers.append(allocator, server);
    return server;
}

fn observeServer(address: [*:0]const u8, queries: u64, failed_queries: u64, nxdomain_replies: u64, retries: u64) callconv(.c) void {
    const name = std.mem.span(address);
    const server = for (servers.items) |known| {
        if (std.mem.eql(u8, known.address, name)) break known;
    } else createServer(name) catch return;

    for ([_]u64{ queries, failed_queries, nxdomain_replies, retries }, &server.values) |value, *slot|
        slot.store(value, .monotonic);
}

fn recordUpstreamLatency(server: [*:0]const u8, millis: f64) callconv(.c) void {
    const value = intern(std.mem.span(server)) orelse return;
    upstream_latency.record(millis, .{ "server.address", value }) catch {};
}

/// The OpenTelemetry severity numbers of the syslog priorities, from its specification:
/// https://opentelemetry.io/docs/specs/otel/logs/data-model-appendix/#appendix-b-severitynumber-example-mappings
const syslog_severities = [_]struct { number: u8, text: []const u8 }{
    .{ .number = 21, .text = "EMERG" },
    .{ .number = 19, .text = "ALERT" },
    .{ .number = 18, .text = "CRIT" },
    .{ .number = 17, .text = "ERR" },
    .{ .number = 13, .text = "WARNING" },
    .{ .number = 10, .text = "NOTICE" },
    .{ .number = 9, .text = "INFO" },
    .{ .number = 5, .text = "DEBUG" },
};

fn log(priority: c_int, facility: [*:0]const u8, message: [*:0]const u8) callconv(.c) void {
    const severity = syslog_severities[@intCast(std.math.clamp(priority, 0, syslog_severities.len - 1))];
    // dnsmasq's facilities are "-dhcp", "-tftp", ...: the dash is for its log line, and there is none for DNS
    const name = std.mem.trimStart(u8, std.mem.span(facility), "-");
    const attributes = [_]sdk.Attribute{
        .{ .key = "dnsmasq.facility", .value = .{ .string = name } },
    };
    logger.emit(.{ .severity = severity.number }, std.mem.span(message), .{
        .severity_text = severity.text,
        .attributes = if (name.len > 0) &attributes else null,
    });
}
