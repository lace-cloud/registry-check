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
- that it carries a version the registry does not hold. A changed directory
  must carry a version the registry does not hold: the check asks the
  registry, with `lace registry get`, which versions of the manifest's
  `<axis>/<author>/<name>` it holds, and refuses one it already holds — a
  version published before, a version a branch reverted to, whatever the base
  branch declares. A version the base branch declares but the registry never
  published passes;
- for a module, that `lace module validate` passes and the verdict is
  `already-lace-style`, resolving each `lace.cloud/` child as the module's
  audience does (below). A module whose child its audience cannot see fails,
  naming the child.

What depends on who publishes is decided only by the publish: whether the
token may act as the manifest's `author`, whether an `in-tree` runtime may
publish to the public catalog, and a module's archive and certification.

The check validates against the Lace API named by `api-url`, which runs the
validator of the Lace release deployed there. A field that is merged in Lace
but not yet deployed to that API is refused by the check.

Every changed manifest is checked. A failure is recorded, the action goes on to
the next manifest, and the step fails at the end naming each failed one. The
job summary holds a table of every manifest, its axis and its result.

## Visibility and the token

Set `visibility` to the visibility the manifests publish with.

`visibility: public` (the default) needs no credential. The public registry
answers anyone, so the check asks it with none: `lace registry get --view
public` for the versions it holds, and `lace module validate --view public`,
which resolves each `lace.cloud/` child as a public module's publish does. A
public module's children must be public, so a public module that calls an
org-private child fails the check, naming the child. Fork pull requests, which
receive no repository secrets, are checked the same way.

`visibility: org_private` reads your organization's private registry, so it
needs the `token` input: an org service token carrying `registry:read` and no
publish scope. Without one the check fails before it checks anything, naming
the input. With it, the check asks the registry and validates each module as
that organization.

```yaml
      - uses: lace-cloud/registry-check@v1
        with:
          token: ${{ secrets.LACE_READ_TOKEN }}
          visibility: org_private
```

The `token` must carry no publish scope. Never pass the publish token to this
action: it runs on `pull_request`, where the pull request's Terraform could
read it. The CLI keeps every Lace credential out of Terraform's environment,
but the check should still not hold a credential that can publish.

A public check cannot see an org-private module. A module's identity names no
visibility, so a module your organization already published privately at the
same `<author>/<name>` and version passes a public check and is refused at
publish: `409 conflict`, or `visibility_mismatch` when the content is
byte-identical. Publish it under a new version.

## Inputs

| Input | Default | |
|---|---|---|
| `token` | none | A service token of the publishing organization carrying `registry:read` and no publish scope. Required for `visibility: org_private`; a public check sends none. |
| `visibility` | `public` | `public` or `org_private`: the registry visibility the manifests publish with. |
| `api-url` | `https://lace.cloud` | The Lace API whose registry and validator check each manifest, and the one the token belongs to. |

## Requirements

- The action runs on `pull_request` and refuses every other event.
- It fetches the pull request's base commit itself, so the default shallow
  checkout is enough; leave `persist-credentials` at its default so it can.
  When it cannot fetch the base it fails, naming the cause.
- The Lace API at `api-url` reachable from the runner. The action installs the
  `lace` release it pins.
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
