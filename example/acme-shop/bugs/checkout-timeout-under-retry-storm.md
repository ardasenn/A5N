---
title: "Checkout 504s when the payment provider slows down"
tags: [acme-shop, bug, checkout, payments]
source: acme-shop/sources/sessions/2026-03-14-checkout-timeout-investigation.md
date: 2026-03-14
status: active
state: pending
---

# Checkout 504s when the payment provider slows down

## Root cause

`PaymentClient` retries three times, immediately, with no shared budget, and
every attempt takes a fresh connection from a pool of 50. When the provider
degrades from 120 ms to 900 ms, 50 in flight requests turn into 150 attempted
connections. The pool empties, unrelated checkout calls queue behind it, and
the gateway times out at 30 seconds.

The provider slowdown by itself was survivable. The retry configuration is
what turned it into an outage. See `services/payment/PaymentClient.kt:88` for
the retry block and `services/payment/PoolConfig.kt:14` for the pool size.

## Impact

About four percent of checkout requests failed for six minutes during the
Tuesday evening peak. Roughly 340 carts affected. No double charges: the
failures happened before the provider was called, not after.

## Fix

A per request retry budget was merged in PR #212: all attempts for one
checkout share a 2 second ceiling, and a retry that would exceed it is
abandoned rather than queued. Verified against the local 900 ms stub, where
failures went to zero and p99 latency rose to 1.9 seconds, which is the
intended tradeoff.

## Status

Merged to `main`, not deployed yet. Production still runs the old build, so
the next provider slowdown will reproduce this exactly as before. A circuit
breaker was discussed as a second layer and deliberately left out of this
change, see [[retry-budget-belongs-to-the-caller]].

## Sources

- acme-shop/sources/sessions/2026-03-14-checkout-timeout-investigation.md

## Related

- [[retry-budget-belongs-to-the-caller]]
- [[payment-client]]
