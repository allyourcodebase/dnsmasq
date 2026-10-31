/* OpenTelemetry hooks for dnsmasq, enabled by -Dotel.

   The patched dnsmasq sources call the dnsmasq_otel_* functions, implemented in glue.c,
   which knows dnsmasq's data structures. They call the otel_* ones, implemented in otel.zig
   with the OpenTelemetry SDK for Zig. */

#ifndef DNSMASQ_OTEL_H
#define DNSMASQ_OTEL_H

#include <stdarg.h>
#include <stdint.h>

struct server;
struct frec_src;

/* Called by the patched dnsmasq. Each is a no-op in a process other than the one
   which started the SDK: forked TCP and script helpers have none of its threads. */

/* Start the SDK, once the daemon is running: it uses threads, which do not survive a fork. */
void dnsmasq_otel_init(void);
/* Say what dnsmasq's counters are worth. Called on every loop of the event loop. */
void dnsmasq_otel_poll(void);
/* A reply was received from an upstream server. */
void dnsmasq_otel_upstream_reply(struct server *server, unsigned int millis);
/* A query arrived. It is answered either by dnsmasq (cache, hosts, ...) or, once it is forwarded
   (to each of those who asked it, if they are several), by an upstream server. */
void dnsmasq_otel_query_received(void);
void dnsmasq_otel_query_answered_locally(void);
void dnsmasq_otel_query_forwarded(const struct frec_src *src);
void dnsmasq_otel_query_answered(const struct frec_src *src);
/* A message is being logged. */
void dnsmasq_otel_log(int priority, const char *facility, const char *format, va_list ap);

/* Implemented in Zig. Return 0 on success. */
int otel_start(void);
void otel_stop(void);
/* The cumulative value of a counter, and the same for an upstream server. They are exported as such.
   A gauge is a value which goes up and down. */
void otel_observe_counter(const char *name, uint64_t value);
void otel_observe_gauge(const char *name, uint64_t value);
void otel_observe_server(const char *address, uint64_t queries, uint64_t failed_queries,
			 uint64_t nxdomain_replies, uint64_t retries);
void otel_record_upstream_latency(const char *server, double millis);
void otel_record_query_duration(int upstream, double millis);
void otel_log(int priority, const char *facility, const char *message);

#endif
