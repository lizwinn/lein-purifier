# Commands

All commands run from the repository root.

## Checks

```zsh
nix flake check
```

The flake checks build the fixtures under `tests/fixtures` in the Nix
sandbox from their committed lockfiles, run their launchers and tests,
run the unit tests of the lock run's parsing (`tests/unit.sh`), build the
`lein-purifier` command (which runs shellcheck), check formatting, and run
these conformance checks of the purifier contract:

- `conformance-stale`: a lockfile made from another project definition or
  with another Leiningen is refused, naming the command to run.
- `conformance-tampered`: a lockfile with a changed hash is refused.
- `conformance-missing`: a lockfile without a needed entry is refused, or,
  when it is otherwise sound, the build fails offline and says to relock.
- `conformance-malformed`: a lockfile with merge conflict markers, one that
  is not a lockfile and one of another format are refused.
- `conformance-external`: a fixture builds from a lockfile outside its
  source.

The fixtures cover these cases:

- `hello`: dependencies from Maven Central and Clojars, a plugin, a test
  profile and an uberjar with a main class.
- `sources`: a version range, a SNAPSHOT, a repository inside the
  project, and Maven Central through a mirror that `profiles.clj`
  configures.
- `multi-sub`: lein-sub subprojects, listed out of dependency order.
- `monolith`: lein-monolith subprojects, one of which inherits from the
  metaproject.

## Checks outside the sandbox

The conformance checks that need Nix or the network outside the sandbox
are scripts, and CI runs each as a job of the same name, on x86_64-linux
and aarch64-linux:

```zsh
tests/relock.sh    # conformance-relock: relocking reproduces each lockfile byte for byte
tests/rebuild.sh   # conformance-rebuild: nix build --rebuild gives the same output
tests/offline.sh   # conformance-offline: after prefetch, the loop works with no network
tests/publish.sh   # publish deploys the jars and POMs of the release
```

The relock needs the network, and all four need the Nix daemon.

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

`LEIN_PURIFIER_TRACE=1` makes `lein-purifier` and its `lein` print each
command they run.
