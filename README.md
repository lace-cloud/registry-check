# Lace Registry Check

A GitHub Action that checks the [Lace](https://lace.cloud) registry artifacts a
pull request changes, with no credential. It is published from the Lace
monorepo; changes are made there, not here.

Add `.github/workflows/check.yml` to the repository that holds your
artifacts:

```yaml
# .github/workflows/check.yml
name: check
on:
  pull_request:
    branches: [main]
permissions:
  contents: read
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: lace-cloud/registry-check@v1
```

Pair it with [`lace-cloud/registry-publish`](https://github.com/lace-cloud/registry-publish)
on pushes to `main`.

## What it checks

For each artifact directory the pull request changes, the action requires:

- the manifest envelope keys (`apiVersion`, `axis`, `author`, `name`,
  `version`, `displayName`) and an `axis` of `module`, `scanner`, `handler` or
  `agent`;
- a `runtime` block on a scanner, handler or agent, and none on a module: a
  module is Terraform a runner applies, so it has no runtime;
- a bumped `version` when the manifest already exists on the base branch;
- for a module, that `lace module validate` passes and the verdict is
  `already-lace-style`.

A module that calls modules from `lace.cloud/` is not validated: that needs a
registry credential a pull request does not hold, and its publish validates
it. The check reports a notice and skips it.

Every changed manifest is checked. A failure is recorded, the action goes on to
the next manifest, and the step fails at the end naming each failed one. The
job summary holds a table of every manifest, its axis and its result.

## Inputs

| Input | Default | |
|---|---|---|
| `lace-version` | the release this version of the action was published with | The `lace` release to check with, as `vX.Y.Z`. |

## Requirements

- The action runs on `pull_request` and refuses every other event. It takes no
  token and no secret, and fork pull requests are checked the same way.
- It fetches the pull request's base commit itself, so the default shallow
  checkout is enough; leave `persist-credentials` at its default so it can.
  When it cannot fetch the base it fails, naming the cause.
- `curl` and `jq` on the runner. `ubuntu-latest` has both; a `container:` job
  needs them in the image. The action installs `minisign` with `apt-get` when
  the runner lacks it, using `sudo` unless the job already runs as root.

## Versions

`v1` moves to the newest `v1.N` release; `v1.N` never changes. Each `v1.N`
installs the `lace` release that was current when it was published, after
verifying the installer's signature under Lace's release-signing key. Pin
`@v1.N` to hold a release still, or pass `lace-version` to hold the CLI alone.

## License

[BUSL-1.1](./LICENSE)
