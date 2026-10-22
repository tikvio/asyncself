# Dependency and Start Gates

Every DAG edge must represent a real prerequisite, not merely a preferred
execution order.

Initial state rules:

- A node with an unchecked human Start Gate begins in `Needs Info`.
- Otherwise, a node with dependencies begins in `Waiting`.
- A root node with all Start Gates satisfied begins in `Todo`.

Use checkbox prefixes consistently:

- `- [ ] human: ...` requires a person to supply or approve something.
- `- [ ] dep:ISSUE-ID dependency completed` is generated for a dependency.
- `- [x] ...` records a prerequisite already satisfied when the plan is
  approved.

Do not use a dependency edge for shared context alone. Put shared context in the
task body or extract a genuine producer task whose output downstream nodes can
verify.

Keep human gates specific and falsifiable. “Design confirmed” is weak;
“Response schema and error codes approved” is actionable.
