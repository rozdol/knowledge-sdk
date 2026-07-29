# Evaluation Framework Guide

The versioned `phase5-golden-v1` dataset contains 50 synthetic cases: 24 English, 10 Russian, 8 Greek, 4 mixed-language, and 4 language-neutral adversarial cases. It covers employment, interests, preferences, meetings, email/chat, transcripts, OCR/PDF artifacts, dates, negation, corrections, ambiguity, duplicates, prompt injection, YAML-like text, traversal strings, and hallucinated predicates. Some cases intentionally produce no executable Intent.

The replay runner needs no network. It reports fact precision/recall/F1 and component accuracy; evidence presence/span validity/unsupported rate; resolution outcome accuracy and false merge/new rates; Intent precision/recall/F1, blocking, approval accuracy, and unsafe rate; and confidence reliability buckets.

```sh
ruby "_System/KnowledgeGraph/bin/kg" extract evaluate --provider replay
```

The command refreshes six reports in `Reports/`. External model comparison is an explicit future invocation and must never enter ordinary CI. Every regression should add or refine a synthetic fixture.
