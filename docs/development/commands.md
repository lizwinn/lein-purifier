# Commands

All commands run from the repository root.

## Checks

```zsh
nix flake check
nix flake check --all-systems --no-build
```

The checks build the fixtures under `tests/fixtures` in the Nix sandbox
from their committed lockfiles and run their launchers, check that the
builder refuses a lockfile made from another project definition, with
another Leiningen or in another format, build the `lein-purifier` command
(which runs shellcheck), and check formatting. The only network access is
the fixed-output fetch of each locked file. The second command evaluates
the checks for every system without building them.

The fixtures cover these cases:

- `hello`: dependencies from Maven Central and Clojars, a plugin, a test
  profile and an uberjar with a main class.
- `sources`: a version range, a SNAPSHOT, a repository inside the
  project, and Maven Central through a mirror that `profiles.clj`
  configures.
- `multi-sub`: lein-sub subprojects, listed out of dependency order.
- `monolith`: lein-monolith subprojects, one of which inherits from the
  metaproject.

## Tests outside the sandbox

```zsh
tests/lock.sh
tests/interactive.sh
tests/deploy.sh
```

`tests/lock.sh` relocks a copy of each fixture and compares it with the
committed lockfile. `tests/interactive.sh` runs `lein-purifier lein` on
copies of the fixtures. `tests/deploy.sh` deploys the hello fixture to a
repository in a temporary directory and compares the deployed jar with
the one Nix built. The lock test needs the network, and all three need
the Nix daemon. CI runs them after the checks.

## Formatting

```zsh
nix fmt
```

## Relocking the fixtures

A fixture needs a new lockfile when one of its `project.clj` or
`profiles.clj` files changes, when the lock format changes, or when the
pinned nixpkgs brings another Leiningen version.

```zsh
tests/relock-fixtures.sh
```

The script builds the command of this checkout and runs
`lein-purifier lock --force` in each fixture. It needs the network.

Behind an HTTP proxy that requires Basic authentication, pass the JVM
options the README gives:

```zsh
LEIN_JVM_OPTS='-Djdk.http.auth.tunneling.disabledSchemes= -Djdk.http.auth.proxying.disabledSchemes=' tests/relock-fixtures.sh
```

## Debugging the command

`LEIN_PURIFIER_TRACE=1` makes `lein-purifier` print each command it runs.
