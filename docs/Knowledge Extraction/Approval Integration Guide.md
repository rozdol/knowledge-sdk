# Approval Integration Guide

Default policy is `review_all`. Low, medium, and high risk labels aid review; all executable changes require human review unless configuration explicitly permits selected low-risk proposals. This phase does not enable automatic execution.

High risk includes merge/split, remove/replace relationship, rename, and archive. Updates and identity-bearing Person/Organization creation are medium. Engine-gated ontology creation uses `explicit_engine_approval` and keeps `human_approved: false` until an approval receipt for the exact immutable proposal exists.

`proposal approve` stores actor, timestamp, approved planned-Intent IDs, and proposal fingerprint outside canonical Markdown. `proposal submit` verifies that fingerprint, skips blocked/unapproved operations, reconstructs existing Intents, sets an Engine approval field only for exactly approved gated operations, and calls `Engine#execute`. Engine validation, rollback, audit, and durable idempotency remain authoritative.
