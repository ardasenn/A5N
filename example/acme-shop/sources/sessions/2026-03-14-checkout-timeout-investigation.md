---
title: "Checkout timeouts under load, root cause found, fix deferred"
tags: [acme-shop, sources, checkout, incident]
source: acme-shop/raw/sessions/8f2c1d90-4a77-4e21-bb03-9c5e1f77a204.jsonl
date: 2026-03-14
status: active
---

# Checkout timeouts under load, root cause found, fix deferred

## Goal

Checkout started returning 504 for about four percent of requests during the
Tuesday evening peak. The task was to find out why, not to ship a fix.

## What was done

Read the gateway access logs for the peak window, then the payment service
traces for the same window. Three things lined up:

1. The payment provider slowed from about 120 ms to about 900 ms for roughly
   six minutes. Their status page showed nothing, which is normal for a
   degradation this short.
2. `PaymentClient` retries three times with no delay and no shared budget.
   Each retry opens a new connection.
3. The connection pool is sized at 50. Under the retry pattern above, one slow
   provider turns 50 in flight requests into 150 attempted connections, so the
   pool empties and unrelated checkout calls queue behind it until the gateway
   gives up at 30 seconds.

The provider slowdown alone was survivable. Requests would have been slow, not
failed. The retry configuration is what turned a slowdown into an outage.

Reproduced locally by putting a 900 ms delay in front of the payment stub:
four percent failures at the same concurrency, close enough to production to
call it confirmed.

## Findings

See [[checkout-timeout-under-retry-storm]] for the root cause writeup.

## Open questions

- No fix was written. Two options were sketched: a per request retry budget,
  or a circuit breaker in front of the provider. Nobody picked one during the
  session.
- Nothing checks whether other services share this retry pattern. `SearchClient`
  looked similar in passing but was not verified.

## Sources

- acme-shop/raw/sessions/8f2c1d90-4a77-4e21-bb03-9c5e1f77a204.jsonl (2026-03-14, 09:12 to 10:40 UTC)

## Related

- [[checkout-timeout-under-retry-storm]]
- [[payment-client]]
