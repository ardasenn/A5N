---
title: "Retry without a budget turns a slowdown into an outage"
tags: [pattern, resilience]
source: acme-shop/bugs/checkout-timeout-under-retry-storm.md
date: 2026-03-16
status: active
---

# Retry without a budget turns a slowdown into an outage

> A retry policy with no ceiling multiplies load exactly when the dependency
> can least afford it. The dependency does not have to fail for this to hurt,
> it only has to get slow.

## The lesson

Retries are usually added to survive a dependency that fails. They behave
completely differently when the dependency gets slow instead. A failure
returns fast and the retry costs little. A slowdown holds every attempt open,
so N retries hold N times the resources for N times as long, and whatever pool
those resources come from empties. Traffic that has nothing to do with the
slow dependency then queues behind an exhausted pool, which is how one
degraded provider takes down an unrelated feature.

The fix is a ceiling that belongs to the caller: one logical request may spend
at most X on retries in total, however it splits them. That caps the
amplification at the entrance instead of reacting after the damage.

Ask two questions of any retry policy:

1. What happens if the dependency answers in ten times the usual time rather
   than failing?
2. Which finite resource does an in flight attempt hold, and how many of them
   exist?

If the answer to the second one is a pool smaller than concurrency multiplied
by attempts, the policy is an amplifier.

## Where this came from

- **acme-shop**, [[checkout-timeout-under-retry-storm]] (2026-03-14): a
  payment provider slowed from 120 ms to 900 ms for six minutes. Three
  immediate retries against a pool of 50 turned 50 in flight requests into 150
  attempted connections. Four percent of checkouts failed, including ones that
  never touched payments. Resolved with a per request budget rather than a
  circuit breaker, see [[retry-budget-belongs-to-the-caller]].

Add the next project's occurrence here rather than starting a new page. A
pattern page earns its keep by collecting instances.

## Related

- [[checkout-timeout-under-retry-storm]]
- [[retry-budget-belongs-to-the-caller]]
