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

To update: copy NavGraph's `docs/lsp.md` over `lsp.md`, then bring
`schema.lua` in line with it. `tests/cases/contract_spec.lua` fails if a
`navgraph/*` method reachable from `epicenter.client` has no schema.
