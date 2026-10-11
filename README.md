# Lace Registry Check

A GitHub Action that checks the [Lace](https://lace.cloud) registry artifacts a
pull request changes, without a publish credential. It is published from the Lace
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

- that the manifest and its README pass `lace registry validate`, the
  validation the registry's publish runs on the same bytes: the envelope, the
  axis and its runtime shape, the identity fields, and every axis-specific
  rule. A refusal carries the publish's own message in the log and an error
  annotation on the manifest;
- a bumped `version` when the manifest already exists on the base branch;
- for a module, that `lace module validate` passes and the verdict is
  `already-lace-style`.

What depends on who publishes or on what the registry already holds is
decided only by the publish: whether the token may act as the manifest's
`author`, whether an `in-tree` runtime may publish to the public catalog,
whether the version is already published with other content, and a module's
archive and certification.

The check validates against the Lace API named by `api-url`, which runs the
validator of the Lace release deployed there. A field that is merged in Lace
but not yet deployed to that API is refused by the check.

A module that calls modules from `lace.cloud/` needs a registry credential to
validate in Lace form. Without a `token` the check reports a notice and skips
that validation, and its publish validates it. With a `token`, the check
validates it as the registry view its `visibility` names.

Every changed manifest is checked. A failure is recorded, the action goes on to
the next manifest, and the step fails at the end naming each failed one. The
job summary holds a table of every manifest, its axis and its result.

## Inputs

| Input | Default | |
|---|---|---|
| `token` | none | Optional. A service token carrying `registry:read` and no publish scope. |
| `visibility` | `public` | `public` or `org_private`: the registry visibility the module publishes with, which selects the view a module that calls `lace.cloud/` modules is validated against. |
| `api-url` | `https://lace.cloud` | The Lace API the token belongs to and whose validator checks each manifest. |

`visibility: public` validates against the public registry only, which is what
a public module's publish resolves its children against, so a private child is
refused naming it. `visibility: org_private` validates as the registry view the
token's own organization binding gives it, which is what an
organization-private publish resolves against. The `token` must be an org
service token carrying `registry:read`, the scope that reads the catalog and
mints a registry read token without submitting Runs or publishing; the API
refuses a user API key that names no organization. Set `visibility` to the
visibility the module publishes with.

The `token` must carry no publish scope. Never pass the publish token to this
action: it runs on `pull_request`, where the pull request's Terraform could
read it. The CLI keeps the token out of Terraform's environment, but the check
should still not hold a credential that can publish.

```yaml
      - uses: lace-cloud/registry-check@v1
        with:
          token: ${{ secrets.LACE_READ_TOKEN }}
          visibility: public
```

## Requirements

- The action runs on `pull_request` and refuses every other event. It takes no
  token by default, and fork pull requests are checked the same way. A fork
  pull request does not receive repository secrets, so a module that calls
  `lace.cloud/` is skipped there.
- It fetches the pull request's base commit itself, so the default shallow
  checkout is enough; leave `persist-credentials` at its default so it can.
  When it cannot fetch the base it fails, naming the cause.
- The Lace API at `api-url` reachable from the runner, with no credential:
  the validation needs a Lace CLI of `v2.43.0` or later, which the action
  installs at the release it pins.
- `curl` and `jq` on the runner. `ubuntu-latest` has both; a `container:` job
  needs them in the image. The action installs `minisign` with `apt-get` when
  the runner lacks it, using `sudo` unless the job already runs as root.

## Versions

`v1` moves to the newest `v1.N` release; `v1.N` never changes. Each `v1.N`
installs the `lace` release that was current when it was published, after
verifying the installer's signature under Lace's release-signing key. Pin
`@v1.N` to hold a release still.

## License

[BUSL-1.1](./LICENSE)
