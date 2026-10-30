/* OpenTelemetry hooks for dnsmasq, enabled by -Dotel: see otel.h.

   This file knows dnsmasq's data structures, and hands plain values to otel.zig. */

#include "dnsmasq.h"
#include "otel.h"

#define MAX_SERVERS 64
#define MAX_MESSAGE 1024

/* The process running the SDK, or 0 before it is started and after it is stopped */
static pid_t otel_pid = 0;

/* The counters, as named in the telemetry, and what they were worth when last said */
static char names[__METRIC_MAX][64];
static unsigned int said_metric[__METRIC_MAX];
static int said_gauge = 0;

static int active(void)
{
  return otel_pid != 0 && getpid() == otel_pid;
}

static void stop(void)
{
  if (active())
    {
      /* Hooks do nothing from now on */
      otel_pid = 0;
      otel_stop();
    }
}

void dnsmasq_otel_init(void)
{
  int i;

  if (otel_start() != 0)
    {
      my_syslog(LOG_WARNING, _("cannot start OpenTelemetry"));
      return;
    }

  for (i = 0; i < __METRIC_MAX; i++)
    snprintf(names[i], sizeof(names[i]), "dnsmasq.%s", get_metric_name(i));

  otel_pid = getpid();
  atexit(stop);
  my_syslog(LOG_INFO, _("OpenTelemetry started"));
}

void dnsmasq_otel_poll(void)
{
  int i;
  struct server *serv;
  /* The upstream servers, which may be several entries each, for different domains */
  struct {
    char address[ADDRSTRLEN];
    uint64_t queries, failed_queries, nxdomain_replies, retries;
  } sums[MAX_SERVERS];
  int count = 0;

  if (!active())
    return;

  for (i = 0; i < __METRIC_MAX; i++)
    {
      /* High water marks, not counters (and only DNSSEC has any) */
      if (i == METRIC_CRYPTO_HWM || i == METRIC_SIG_FAIL_HWM || i == METRIC_WORK_HWM)
	continue;

      if (daemon->metrics[i] != said_metric[i] || (i == METRIC_TCP_CONNECTIONS && !said_gauge))
	{
	  said_metric[i] = daemon->metrics[i];
	  /* The number of processes serving TCP queries now: dnsmasq adds one when it starts one, and removes it when it ends */
	  if (i == METRIC_TCP_CONNECTIONS)
	    {
	      said_gauge = 1;
	      otel_observe_gauge(names[i], said_metric[i]);
	    }
	  else
	    otel_observe_counter(names[i], said_metric[i]);
	}
    }

  for (serv = daemon->servers; serv; serv = serv->next)
    {
      char address[ADDRSTRLEN];

      /* Not every entry is an upstream server: some are an address to answer with */
      if ((serv->flags & SERV_LITERAL_ADDRESS) ||
	  (serv->addr.sa.sa_family != AF_INET && serv->addr.sa.sa_family != AF_INET6))
	continue;

      prettyprint_addr(&serv->addr, address);

      for (i = 0; i < count; i++)
	if (strcmp(sums[i].address, address) == 0)
	  break;

      if (i == count)
	{
	  if (count == MAX_SERVERS)
	    continue;
	  memset(&sums[count], 0, sizeof(sums[count]));
	  strcpy(sums[count++].address, address);
	}

      sums[i].queries += serv->queries;
      sums[i].failed_queries += serv->failed_queries;
      sums[i].nxdomain_replies += serv->nxdomain_replies;
      sums[i].retries += serv->retrys;
    }

  for (i = 0; i < count; i++)
    otel_observe_server(sums[i].address, sums[i].queries, sums[i].failed_queries,
			sums[i].nxdomain_replies, sums[i].retries);
}

void dnsmasq_otel_upstream_reply(struct server *server, unsigned int millis)
{
  char addr[ADDRSTRLEN];

  if (!active())
    return;

  prettyprint_addr(&server->addr, addr);
  otel_record_upstream_latency(addr, millis);
}

void dnsmasq_otel_log(int priority, const char *facility, const char *format, va_list ap)
{
  char message[MAX_MESSAGE];

  if (!active())
    return;

  vsnprintf(message, sizeof(message), format, ap);
  otel_log(priority, facility, message);
}
