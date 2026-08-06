---
title: "PaymentClient"
tags: [acme-shop, entity, payments]
source: acme-shop/sources/sessions/2026-03-14-checkout-timeout-investigation.md
date: 2026-03-14
status: active
---

# PaymentClient

The only path from checkout to the payment provider. Lives at
`services/payment/PaymentClient.kt`.

## What it does

Takes a cart and a payment method, calls the provider, returns an
authorisation or an error. Synchronous, called once per checkout attempt.

## Things worth knowing

- Connection pool is 50, set in `services/payment/PoolConfig.kt:14`. That
  number predates the current traffic and nobody has revisited it.
- Retry behaviour is the interesting part and it caused a real outage, see
  [[checkout-timeout-under-retry-storm]].
- `SearchClient` looks like it shares the same retry shape. Never verified,
  worth an hour when someone is nearby.

## Sources

- acme-shop/sources/sessions/2026-03-14-checkout-timeout-investigation.md

## Related

- [[checkout-timeout-under-retry-storm]]
- [[retry-budget-belongs-to-the-caller]]
