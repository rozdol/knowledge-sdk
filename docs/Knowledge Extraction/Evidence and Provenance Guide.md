# Evidence and Provenance Guide

Every fact requires at least one `EvidenceSpan`. Plain text prefers exact character offsets and an excerpt that must equal the normalized source slice. PDF text may add a page. Transcripts may add speaker and local timestamps. The validator never fabricates a missing locator.

Every planned Intent records source ID/hash, fact IDs, evidence IDs, pipeline version, provider/model, prompt version, relevant resolution decisions, risk, and approval classification. Proposal validation rejects unknown fact/evidence references or source mismatch.

Evidence excerpts are length-limited. Proposals store source metadata and evidence snippets, not another full transcript copy. Canonical graph provenance, when executed, remains governed by the existing Intent and schema fields; the proposal artifact is review evidence, not a second source of truth.
