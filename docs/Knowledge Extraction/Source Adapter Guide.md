# Source Adapter Guide

`SourceDocument` supports `text`, `chat`, `meeting-notes`, `email-text`, `transcript`, `ocr-text`, and `pdf-text`. Every adapter preserves arbitrary metadata, original language, capture time, URI/external identity, participants, and normalized content hash.

Normalization performs UTF-8 repair, NFC normalization, newline normalization, and NUL removal. It never translates names. English, Russian, Greek, mixed, and undetermined language codes are supported. Source size is bounded by configuration.

Voice, OCR, and PDF sources enter as already extracted text. Page, speaker, and timestamp metadata belong on evidence spans. Future Whisper, OCR, PDF, email, Telegram, calendar, and browser connectors should return `SourceDocument`; they must not call graph writers.

Relative dates resolve only when `captured_at` supplies a reliable reference instant. The resulting scalar retains original expression, normalized value/range, normalization confidence, and uncertainty. Without context, the expression stays unresolved.
