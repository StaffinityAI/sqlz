# ADR 0024: Applied state and operation journal

- Status: Accepted
- Date: 2026-09-03

## Context

A single dirty flag cannot explain multi-revision command interruption.

## Decision

Store the applied set plus an append-only command-run table and ordered
per-revision step table. Retain indefinitely until explicit prune and persist only
safe error context.

## Alternatives considered

One dirty bit, overwriting the last run, and automatic retention expiry were
rejected.

## Consequences

Recovery is auditable but state grows until operators prune it.

## Normative references

- [Migration state](../migration-state.md)
