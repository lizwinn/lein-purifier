# lein-purifier

lein-purifier builds [Leiningen](https://leiningen.org) projects in the Nix
sandbox. `lein-purifier lock` records every file Leiningen downloads in
`lein-purifier.lock.json`, and Nix builds the project from that lockfile,
offline. You commit the lockfile, and no generated Nix files. lein-purifier
is one of the [nix-purifiers](https://nix-purifiers.github.io), and it meets
their [contract](https://github.com/nix-purifiers/purifier/blob/main/CONTRACT.md).

## Quickstart

Lock the project from its root, and commit the lockfile:

```zsh
nix run github:nix-purifiers/lein-purifier -- lock
```

Build it with the builder of the flake's library:

```nix
{
  inputs.lein-purifier.url = "github:nix-purifiers/lein-purifier";
  inputs.nixpkgs.follows = "lein-purifier/nixpkgs";

  outputs = { nixpkgs, lein-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      project = lein-purifier.lib.lein-purifier.buildLeinProject {
        inherit pkgs;
        src = ./.;
      };
    in
    {
      packages.${system}.default = project.packages.hello;
      checks.${system}.tests = project.tests;
    };
}
```

`nix build` then builds the project. The builder's result has:

- `packages.<name>`: a package for each project, named after it, with the
  jar, the uberjar and the POM in `share/java`, and a launcher in `bin` for
  a project with `:main`. A package lists its jars in `artifacts`, such as
  `artifacts."hello-1.0.0-standalone.jar"`, which are known from the
  lockfile before the build runs.
- `tests`: `lein test` of every project, in the sandbox.
- `release`: the jar and the POM of every project in Maven repository
  layout, which `lein-purifier publish` deploys.
- `fetches`: the entries of the lockfile, for SBOM, license and
  vulnerability tools.

`lein-purifier.lib.lein-purifier.readLock { src, lockFile ? ... }` reads
the lockfile into the shape every purifier shares: `purifier`, the
download `entries`, the `outputs` of each project (its directory, group,
version, main class, jars and the projects of the build it depends on)
and the `problems` that stop a build, each naming the command to run. The
builder reads the lockfile through it.

The builder also takes `fetchers` (passed to the shared library's
`fetchEntry`, such as a `fetchurl` with credentials or a company mirror),
`lockFile` (a lockfile outside `src`, for a project you package but do not
change), `jdk` (the default is the headless JDK of the major version the
lock was made with) and `srcFilter`. We recommend following the nixpkgs
input of lein-purifier, as above: the builder uses the Leiningen of `pkgs`,
and it refuses a lockfile made with another Leiningen version, because each
version adds its own nREPL dependencies to every project.

## Everyday loop

`nix shell github:nix-purifiers/lein-purifier` puts `lein-purifier` and
its `lein` on the `PATH`, as does a development shell with the `cli`
package. Their `lein` is Leiningen itself, which in a project with a
lockfile runs offline on the locked files:

```zsh
lein run
lein test
lein uberjar
```

When you add or upgrade a dependency in `project.clj`, the next `lein`
stops and asks you to relock:

```zsh
lein-purifier lock
```

`lein-purifier lock` copies the project to a temporary directory and runs
`lein with-profile +test deps` and `lein do jar, uberjar, pom` there, with
an empty local Maven repository and no user profile, as a sandboxed build
has. A Leiningen init file logs every download Maven Resolver completes
with the URL it came from. A lock is current while every `project.clj` and
`profiles.clj` of the build is unchanged and the Leiningen version is the
same, and `lein-purifier lock` leaves a current lockfile alone. `--force`
relocks regardless, `--no-uberjar` leaves the uberjars out of the lock and
the build, and `--lockfile PATH` (or `LEIN_PURIFIER_LOCKFILE`) names a
lockfile elsewhere. A relock of an unchanged project gives the same
lockfile byte for byte.

Leiningen has no lockfile of its own, so the versions that a version range
or a SNAPSHOT dependency resolves to are recorded only in
`lein-purifier.lock.json`. `lein-purifier lock` keeps them: it gives the
lock run the repository metadata the lockfile recorded, and Maven Resolver
picks the same versions from it. To move them, run

```zsh
lein-purifier update                        # every version range and SNAPSHOT
lein-purifier update org.clojure/data.json  # only this package
```

which resolves them anew against the repositories and relocks.

Maven Central answers many requests from one address with HTTP 429, so the
lock run downloads its files through Google's mirror of it, unless the
project configures `:mirrors` itself. Each file from Maven Central is
locked with its URL there and with the mirror as the fallback.
`LEIN_PURIFIER_CENTRAL_MIRROR` names another mirror, and an empty value
turns it off.

`lein-purifier publish REPOSITORY [NAME...]` builds the `release` with Nix
and deploys each project's jar and POM with `lein deploy`, so nothing is
compiled outside the sandbox. The repository, its credentials and signing
work as they do for `lein deploy`.

## Offline work

```zsh
lein-purifier prefetch
```

fetches every locked file into the Nix store and lays them out as the
local Maven repository in `.lein-purifier/` at the project root, with GC
roots there for the files and for lein-purifier with its Leiningen and
JDK. `lein` prefetches by itself when the lockfile changed, and after
that, the everyday loop and the editor need no network. Add
`.lein-purifier/` to `.gitignore`.

## Editor

clojure-lsp works with no configuration. It finds the classpath with
`lein with-profile +test,+dev classpath`, and with lein-purifier's `lein`
on the `PATH` of the editor, that runs offline on the prefetched files.
Every dependency of the `dev` and `test` profiles is locked, so the
editor sees the same jars as the build. Start the editor from the shell
that has lein-purifier, or from a development shell with the `cli`
package.

## Errors and fixes

| Message | Cause | Fix |
| --- | --- | --- |
| project.clj or profiles.clj changed, or Leiningen did, after … was made | A dependency, a profile or the Leiningen version changed since the lock | `lein-purifier lock` |
| Leiningen needs an artifact that … does not hold | A task or profile the lock run did not use needs a file | `lein-purifier lock --force` |
| … was changed after lein-purifier lock wrote it | The lockfile was edited by hand | `lein-purifier lock --force` |
| … has merge conflict markers in it, or … is not valid JSON | A merge left the lockfile broken | `lein-purifier lock --force` |
| … has lock format version … | The lockfile is from another lein-purifier | `lein-purifier lock --force` |
| Checksum validation failed, no checksums available | An HTTP proxy that needs Basic authentication, which the JVM refuses by default | Run the lock with `LEIN_JVM_OPTS='-Djdk.http.auth.tunneling.disabledSchemes= -Djdk.http.auth.proxying.disabledSchemes='` |

Nix reports the same messages at evaluation, so a broken lockfile fails
before anything builds. `LEIN_PURIFIER=0 lein` runs Leiningen as itself,
and `LEIN_PURIFIER_TRACE=1` prints each command lein-purifier runs.

## Sources supported and refused

Supported:

- Dependencies and plugins from any Maven repository, Maven Central and
  Clojars included, and from mirrors that `project.clj` or `profiles.clj`
  configures.
- The dependencies of the `test`, `dev` and `uberjar` profiles, and the
  nREPL dependencies Leiningen adds to every project.
- Version ranges and SNAPSHOT versions. Maven Resolver picks those from
  repository metadata, whose content changes over time at its URL, so the
  lock writes the metadata with the versions the lock run downloaded, and
  the timestamped SNAPSHOT files are ordinary downloads. The build resolves
  to the same versions the lock run did.
- Repositories inside the project, such as `:repositories [["local"
  "file:repository"]]`. Their files are not downloads; the build takes them
  from the project source.
- Projects with subprojects, which lein-sub names in `:sub` and
  lein-monolith in its `:project-dirs`. The lock runs each subproject in
  dependency order and installs it into the local repository, and Nix
  builds one package per subproject, with the packages of the subprojects
  it depends on in its local repository.

Refused, and why:

- **Git dependencies and URL tarballs.** Leiningen resolves dependencies
  from Maven repositories only. Git dependencies exist only through
  third-party plugins such as lein-git-down, which fetch with code of their
  own, outside Maven Resolver, so the lock run cannot see those downloads.
- **`file:` repositories outside the project.** Such a repository is a path
  on one machine, which the sandbox cannot read, so the lock run stops when
  a project uses one.
- **Checkouts.** Leiningen checkouts are links from `checkouts/` to other
  projects on the same machine, so the lock run and the sandboxed build
  leave them out. The everyday loop keeps them, since it runs in the
  project itself.
- **The user profile in the lock and the build.** The lock run and the
  sandboxed build ignore `~/.lein/profiles.clj`, so a project that needs
  something from it declares it in `project.clj` or `profiles.clj`. The
  everyday loop keeps the user profile.

Leiningen selects the same artifacts on every platform, so one lockfile
serves x86_64-linux and aarch64-linux. A dependency whose POM activates a
profile by operating system or architecture is the exception: the lock
holds what the platform of the lock run resolved.

## Real-world projects

The test fixtures cover each supported source: `hello` (Maven Central,
Clojars, a plugin, a test profile, an uberjar), `sources` (a version range,
a SNAPSHOT, a mirror, a repository inside the project), `multi-sub`
(lein-sub) and `monolith` (lein-monolith).

## Credits

lein-purifier follows the design of
[sbt-nix-backend](https://github.com/clhodapp/sbt-nix-backend), which is
becoming sbt-purifier: a lock run in the sandbox environment, a lockfile of
downloads and outputs, sandboxed builds, an offline everyday loop and a
publish step from what Nix built. The purifier idea was inspired by
nixcloud's [cargo (libnix)](https://github.com/nixcloud/cargo). It is MIT
licensed.
