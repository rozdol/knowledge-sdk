# Privacy and Security Guide

Safe defaults disable external providers, keep full source content out of logs and proposal JSON, redact token-like secrets in structured logs, and store local proposal artifacts only under Git-ignored Runtime. Debug prompt capture is not implemented.

Source text is hostile data. Embedded tool requests, system-like text, YAML, paths, and approval bypass attempts cannot change the extraction schema, execute tools, select Intents, or set approval. Structured output uses closed field allowlists, size limits, exact evidence validation, and graph registry checks.

Never send `sensitivity: restricted` content externally. Before enabling a cloud callable, review provider retention, training, residency, subprocessors, access logging, and deletion controls. Supply only the smallest entity context needed. Runtime proposals, approvals, and audit logs are private operational metadata and should receive the same backup/access controls as the vault.
