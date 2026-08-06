---
title: "Retry budget lives with the caller, not in a circuit breaker"
tags: [acme-shop, decision, resilience]
source: acme-shop/sources/sessions/2026-03-14-checkout-timeout-investigation.md
date: 2026-03-16
status: active
---

# Retry budget lives with the caller, not in a circuit breaker

## Decision

Checkout gets a per request retry budget. A circuit breaker in front of the
payment provider was considered and rejected for now.

## Reasoning

A breaker fixes the symptom one level too late. It opens after enough
failures, which means the first wave of an outage still lands in full, and it
opens for everybody, including the requests that would have succeeded on their
first attempt. The budget caps the damage on the way in instead: one checkout
can spend two seconds on retries and no more, whether that is one slow attempt
or three fast ones.

The breaker also adds a piece of shared state that has to be right, and a
wrong breaker is worse than no breaker. Nobody in the session could say what
the failure threshold should be, which is a good sign that it is not the
change to make today.

## What this does not cover

A provider that is slow for hours rather than minutes. The budget keeps
checkout responsive but every request still pays two seconds before failing.
If that happens, revisit the breaker with real numbers from the incident
rather than guessed thresholds.

## Sources

- acme-shop/sources/sessions/2026-03-14-checkout-timeout-investigation.md

## Related

- [[checkout-timeout-under-retry-storm]]
