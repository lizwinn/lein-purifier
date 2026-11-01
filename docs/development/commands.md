# Commands

All commands run from the repository root.

## Checks

```zsh
nix flake check
```

The checks build the fixtures under `tests/fixtures` in the Nix sandbox
from their committed lockfiles, run the hello launcher, check that the
builder refuses a lockfile made from another project definition or with
another Leiningen, build the `lein-purifier` command (which runs
shellcheck), and check formatting. The only network access is the
fixed-output fetch of each locked artifact.

## Formatting

```zsh
nix fmt
```

## Relocking the fixtures

A fixture needs a new lockfile when its `project.clj` changes, when the
lock format changes, or when the pinned nixpkgs brings another
Leiningen version.

```zsh
tests/relock-fixtures.sh
```

The script builds the command of this checkout and runs
`lein-purifier lock --force` in each fixture. It needs the network.

Behind an HTTP proxy that requires Basic authentication, the JVM refuses
the proxy by default, and Leiningen reports "Checksum validation failed,
no checksums available". `lein-purifier lock` keeps the caller's
`LEIN_JVM_OPTS`, so the fix is to allow Basic authentication for that run:

```zsh
LEIN_JVM_OPTS='-Djdk.http.auth.tunneling.disabledSchemes= -Djdk.http.auth.proxying.disabledSchemes=' tests/relock-fixtures.sh
```
