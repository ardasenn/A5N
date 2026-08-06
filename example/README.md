# Example output

Everything under `acme-shop/` is invented. There is no such project and no
such company. These four pages were written by hand to show what a vault looks
like after the ingest has run for a while, because a screenshot of a folder
tree tells you very little about whether the output is worth having.

A real namespace also carries `raw/sessions/` with the original transcripts,
plus `concepts/`, `syntheses/` and `archive/`. Those are left out here to keep
the example short.

Read them in this order:

1. [A session summary](acme-shop/sources/sessions/2026-03-14-checkout-timeout-investigation.md).
   One agent session, condensed. Every other page traces back to something
   like this.
2. [The bug it found](acme-shop/bugs/checkout-timeout-under-retry-storm.md).
   Root cause and fix, with the state field that the lint keeps honest.
3. [The decision that came out of it](acme-shop/decisions/retry-budget-belongs-to-the-caller.md).
   One decision, one page.
4. [The lesson, generalised](patterns-example/retry-without-a-budget-amplifies-an-outage.md).
   Stack agnostic, so it lives in `patterns/` where a future project will find
   it.

The fourth one is the point of the whole system. The first three are what any
notes folder gives you. A pattern page is what stops the same class of mistake
in a project you have not started yet.
