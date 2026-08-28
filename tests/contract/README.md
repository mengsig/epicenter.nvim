# The editor protocol contract

`lsp.md` is a verbatim copy of NavGraph's `docs/lsp.md`, the v1 editor
protocol. It is vendored so this repository can be read, and its schemas
checked, without a NavGraph checkout.

`schema.lua` is that document as data: one params shape and one result shape
per `navgraph/*` method. Both lanes enforce it.

- Requests are checked **strictly**. A param this plugin sends that the
  contract does not name, or sends with the wrong type, is a `-32602` from the
  fake server and a failed assertion in `tests/cases/contract_spec.lua`. A
  feature written against an imagined shape fails at the first call.
- Responses are checked **forward-compatibly**. Every field the contract
  promises must be present and well-typed; a field a newer server adds is
  ignored rather than rejected, so a server ahead of this plugin still works.

`UPSTREAM.lock` pins the NavGraph revision `lsp.md` was copied at and a
sha256 of the vendored file; `make contract-check` fails when the vendored
copy no longer matches that pin, so a hand-edit or a partial re-vendor is
caught even without a NavGraph checkout to diff against.

To update:

1. From a NavGraph checkout, copy `docs/lsp.md` over this directory's
   `lsp.md` and note `git rev-parse HEAD` there.
2. Bring `schema.lua` in line with the new `lsp.md`, method by method.
3. Update `UPSTREAM.lock`: `upstream_rev` to that revision, `sha256` to
   `sha256sum tests/contract/lsp.md` (or `vim.fn.sha256(...)` on its bytes).
4. `make contract-check` should pass; `tests/cases/contract_spec.lua` fails
   if a `navgraph/*` method reachable from `epicenter.client` has no schema.
