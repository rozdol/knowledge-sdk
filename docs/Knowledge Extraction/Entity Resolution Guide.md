# Entity Resolution Guide

Resolution outcomes are `resolved`, `ambiguous`, `new_entity`, `conflict`, and `insufficient_information`. Candidate records include score, matched signals, conflicts, and explanation.

Exact email/phone scores 0.99; stable external ID/domain scores 0.98; exact name/alias is only a 0.72 candidate signal. Only one conflict-free strong candidate above the automatic threshold resolves. Name-only candidates always require review, and multiple candidates are ambiguous. Conflicting supplied email or phone yields `conflict`.

`KnowledgeGraph::GraphReader` follows merged redirects through the existing resolver and returns metadata-only snapshots. It never returns bodies or mutates storage. The pipeline never produces `MergeEntities` from an extraction, even when duplicates appear; explicit human-approved merge remains a separate Engine operation.
