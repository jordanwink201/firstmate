# Test Layers — Firstmate

Last updated: 2026-07-18

| Artifact type | When to use | Location |
|---|---|---|
| **Shell behavior test** | Script contracts, JSON output, parsing, routing, lifecycle, and state-file behavior | `tests/*.test.sh` |
| **Python behavior test** | Python-owned helper behavior or backend adapters already covered in Python | `tests/*.test.py` |
| **Dashboard render contract** | Dashboard HTML, browser-side render functions, cached probe routes, and UI regressions that can be exercised without a full browser | `tests/fm-dashboard-server.test.sh` |
| **Dashboard probe contract** | Fleet/station JSON mapping, replay sources, arrival ledger rows, report-store rows, and pipeline metadata | `tests/fm-dashboard-probe.test.sh` |
| **Backend smoke/E2E test** | Backend process integration, tmux/herdr/zellij/orca/cmux launch behavior, and lifecycle handoffs | `tests/*smoke*.test.sh`, `tests/*e2e*.test.sh`, backend-specific `tests/fm-backend-*.test.*` |
| **Browser QA helper test** | `bin/fm-browser-qa.sh` URL identity and evidence behavior | `tests/fm-browser-qa.test.sh` |
| **Nothing** | Structural-only changes that fail loudly through shell syntax, existing script tests, or command invocation | — |
