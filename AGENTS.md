# AnyLanguageModel agent guide

## Foundation Models authority

Apple's latest OS 27 Foundation Models public API is the immutable authority for
this package's compatibility contract. `FoundationModels.LanguageModelSession`
and its related types outrank existing AnyLanguageModel implementation details,
older package documentation, provider-specific conveniences, and consumer
workarounds.

Treat the current Apple surface as one contract. This includes
`LanguageModelSession`, `LanguageModel`, `LanguageModelExecutor`, `Transcript`,
`Tool`, `Prompt`, `Instructions`, attachments, `GeneratedContent`, generation
schemas and options, context options, streaming responses, usage, metadata,
errors, cancellation, and session properties. Preserve nonexhaustive entries and
segments, stable identities, ordering, structured content, reasoning, Tool calls
and outputs, attachments, and top-level data rather than flattening them into a
text-message model.

Before changing this surface, inspect the newest available SDK interface and the
current official [`LanguageModelSession`](https://developer.apple.com/documentation/foundationmodels/languagemodelsession),
[Foundation Models updates](https://developer.apple.com/documentation/updates/foundationmodels),
and [provider integration guidance](https://developer.apple.com/videos/play/wwdc2026/339/).
Record when the installed SDK lags newer documentation, and do not claim
compilation or runtime acceptance for an API that is not present in the tested
SDK.

## OS 26 compatibility mirror

Keep OS 26 and other supported environments through an explicit compatibility
mirror of the OS 27 contract. Back deployment does not create a second source of
truth: match Apple's names, generic constraints, concurrency, transcript
mutations, Tool dispatch, streaming, usage, metadata, errors, and cancellation
semantics wherever the platform can express them.

Gate newer syntax and runtime APIs with the applicable compiler and availability
checks while preserving the package's declared deployment floors. When an OS 27
semantic cannot be represented faithfully, fail the affected operation
explicitly and document the gap. Do not silently drop transcript content,
attachments, Tool output, metadata, or side effects; do not substitute a
text-only path, another provider, rebuilt Session, parallel agent loop, or
caller-owned workaround and report that as parity.

Clearly label APIs that Apple does not provide as AnyLanguageModel extensions.
Consumers must not have to depend on an extension as though it were part of the
canonical Foundation Models contract.

## Verification

Contract changes require focused evidence for both paths they affect:

- OS 27 tests exercise the system Foundation Models types and lifecycle.
- Compatibility tests exercise the mirrored path on its supported deployment
  range, including continuation after Tool output and transcript restoration.
- Cross-path scenarios compare observable behavior without treating one passing
  path as proof for the other.

Keep provider wire behavior in provider implementations, session orchestration
in `LanguageModelSession`, and product policy in the consuming application.
Repair a demonstrated defect at its owning layer instead of adding a
consumer-specific exception.
