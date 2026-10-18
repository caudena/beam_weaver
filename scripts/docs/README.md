# Documentation verification

Reader-facing Markdown contains the code that runs. Execution settings belong
in `scenarios.exs`; do not add test-runner comments to guides or example READMEs.
The parser discovers fenced Elixir, IEx and executable indented examples in the
guides, example READMEs and public API documentation. Script coverage comes from
`scripts/examples/manifest.exs`.

Related blocks share bindings within a scenario. The scenario manifest uses
section headings for boundaries and exact code selectors for execution
overrides. Every selector must match exactly once; stale or ambiguous entries
fail verification. Services inferred from the code and explicit requirements
are enabled together. The strict runner executes each scenario in a fresh BEAM
process and uses the repository and application setup printed in the guide.

Documentation checks are separate from `mix test`.
`mix docs.verify --all` executes all discovered examples, all registered scripts
and a fresh consumer application. It requires credentials for all eight
providers and a running Docker daemon. Each PostgreSQL scenario receives its
own disposable pgvector database. Missing requirements remain failures in the
coverage report.

The package consumer installs the built package, executes the onboarding
tutorial, applies the documented configuration, runs the PostgreSQL migrations
and exercises SQLite checkpoints. It does not load repository test support.
Public Hex installation is checked separately and remains pending until the
target release exists and its consumer flow succeeds.

Every run keeps its report, source locations, executed code and logs in
`_build/docs_verify/runs/`. The latest run is also copied to
`_build/docs_verify/report.json`; a selected run does not replace the evidence
stored for an earlier full run. The API inventory distinguishes feature-guide
ownership, literal guide references and member-level documentation. A
`signature_only` member is not claimed to have its own prose documentation.

`provider_tables.exs` generates the provider tables from the checked-in model
profiles. It locates them by page title and table header. `mix docs.providers`
updates tables. `mix docs --warnings-as-errors` builds HexDocs using the same
guide navigation as GitBook.
