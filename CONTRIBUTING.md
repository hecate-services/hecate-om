# Contributing

Trunk-based. Commit directly to `main`. No PRs.

## Build

```bash
rebar3 compile
rebar3 ct
```

## Style

- Erlang: `warnings_as_errors`, dialyzer clean
- Vertical slicing — no `services/`, no `helpers/`
- Every `hecate-services/hecate-X` repo MUST depend on this library
  via `{hecate_om, "~> 0.1"}` and implement the `hecate_om_service`
  behaviour. Don't write a new "service runner" — extend this one.

## Issues

https://codeberg.org/hecate-services/hecate-om/issues
