# Licensing AsyncSelf

AsyncSelf is **source-available under mixed licensing**. It combines an Apache-2.0 upstream work
with separately authored AsyncSelf extensions. The applicable license is determined by the path of
each file, not by a general description of the feature.

## Apache-2.0 scope

Except for the two directory trees listed under **PolyForm Noncommercial scope**, this repository
is licensed under the [Apache License 2.0](LICENSES/Apache-2.0.txt). This includes:

- the OpenAI Symphony-derived core under `elixir/` and all changes made inside those files;
- upstream-derived repository skills under `.codex/skills/`, other than `spec-planner/`;
- launchers, public configuration examples, documentation, workflows, and repository metadata;
- `SPEC.md`, `LICENSE`, and `NOTICE` from the upstream work or their preserved derivatives.

The upstream attribution is preserved in [NOTICE](NOTICE). Nothing in AsyncSelf's mixed-license
policy reduces or replaces the Apache-2.0 rights already granted for OpenAI Symphony material.

## PolyForm Noncommercial scope

The following independently developed AsyncSelf additions are licensed under the
[PolyForm Noncommercial License 1.0.0](LICENSES/PolyForm-Noncommercial-1.0.0.txt):

- every file under `local-tools/`;
- every file under `.codex/skills/spec-planner/`.

Directory-level notices inside both trees repeat this boundary. Unless a file says otherwise, the
notice for its containing tree applies to source, tests, scripts, and documentation in that tree.

Required Notice: Copyright 2026 tikvio (https://github.com/tikvio)

PolyForm Noncommercial permits noncommercial use, modification, and distribution on its terms. It
does not grant commercial-use rights. For commercial licensing of the PolyForm-covered components,
contact **mynewhao@foxmail.com**.

## Provenance statement

AsyncSelf is based on [OpenAI Symphony](https://github.com/openai/symphony), with recorded baseline
commit `e0ccc83720a42a600a53b61c5f8d3e518bebe1db`. Symphony-derived files and direct modifications to
them remain in the Apache-2.0 scope.

The project owner represents that the additions placed in the two PolyForm-covered trees were
developed for AsyncSelf rather than copied from Symphony. AI coding tools assisted parts of the
implementation under the owner's direction and review. This statement does not override any
third-party rights or license notices that may apply.

## Rule for future changes

Direct edits to Symphony-derived files remain Apache-2.0, including new AsyncSelf logic added inside
those files. A future independently authored component may use PolyForm Noncommercial only when it
is kept in a clearly separable path and this document is updated to list that path. Moving or
copying Apache-covered code into a PolyForm directory does not remove its Apache-2.0 license.

This path-based rule is intentional: it keeps future upstream merges and direct Symphony changes
legally understandable while reserving a separate commercial-license option for standalone
AsyncSelf components.

## Contributions

See [CONTRIBUTING.md](CONTRIBUTING.md) before submitting code. In particular, code contributions to
the PolyForm-covered trees require a separate written agreement so the project owner can continue
offering commercial licenses.

Official license texts:

- [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0)
- [PolyForm Noncommercial 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0)

This document describes the repository's license boundary; it is not legal advice.
