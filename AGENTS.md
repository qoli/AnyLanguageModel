# Repository Guidelines

## Project Structure & Module Organization
- `Sources/AnyLanguageModel`: core library implementation and provider integrations.
- `Sources/AnyLanguageModelMacros`: Swift macros used by the main module.
- `Tests/AnyLanguageModelTests`: unit/integration tests.
- `Package.swift`: SwiftPM manifest (traits and dependencies).
- `.swift-format`: formatting rules (source of truth).

## Build, Test, and Development Commands
- `swift build`: compile the package.
- `swift test`: run the default test suite.
- `swift test --traits CoreML,Llama`: enable provider-specific tests via traits.
- `xcodebuild test -scheme AnyLanguageModel -destination 'platform=macOS'`: required for MLX tests (Metal loading). If you change default traits, update `Package.swift` accordingly.

## Coding Style & Naming Conventions
- Indentation: 4 spaces; max line length: 120 (see `.swift-format`).
- Prefer Swift API Design Guidelines: `UpperCamelCase` for types, `lowerCamelCase` for vars/functions.
- Format with swift-format using the repo config, e.g. `swift-format format -r -i Sources Tests`.

## Testing Guidelines
- Tests live in `Tests/AnyLanguageModelTests` and generally follow `*Tests.swift` naming.
- Provider tests may require env vars: `HF_TOKEN`, `LLAMA_MODEL_PATH`, `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`.
- Generation-heavy tests are skipped when `CI` is set; enable locally with `ENABLE_COREML_TESTS=1` or `ENABLE_MLX_TESTS=1` as needed.

## Commit & Pull Request Guidelines
- Commit messages are short, imperative, sentence case (e.g., “Update README”, “Fix missing iOS availability annotations…”). PR numbers are sometimes appended like “(#49)”.
- PRs should include: a concise summary, test command(s) run, and any trait/OS constraints.
- If behavior changes, note API impact and add/adjust tests. Include screenshots only when UI outputs are affected.

## Security & Configuration Tips
- Never hardcode API keys. Use environment variables for local runs and keep credentials out of commits.
