# lein-purifier

A command and a Nix library that build
[Leiningen](https://leiningen.org) projects in the Nix sandbox. The
command records the files Leiningen wants to download in a lockfile, and
Nix builds the project from that lockfile, offline. You commit the
lockfile, and no generated Nix files.

lein-purifier is one of the [nix-purifiers](https://nix-purifiers.github.io).

- **A lockfile.** `lein-purifier lock` writes `lein-purifier.lock.json`
  at the project root. It holds every file the build downloads, by URL
  and SHA-256: dependencies, plugins, the dependencies of the `test` and
  `uberjar` profiles, and the nREPL dependencies Leiningen adds to every
  project. It also names the project, its main class and the jars the
  build produces.
- **Sandboxed builds.** `buildLeinProject` turns a project and its
  lockfile into a package with the jar, the uberjar and the POM in
  `share/java`, and a launcher in `bin` when the uberjar has a main class.
- **Interactive Leiningen on the locked downloads.** `lein-purifier lein`
  runs Leiningen offline, with a local Maven repository that holds exactly
  the locked files.

## How the lock is made

`lein-purifier lock` copies the project to a temporary directory and runs
`lein with-profile +test deps` and `lein do jar, uberjar, pom` there, with
an empty local Maven repository and no user profile. That is the
environment a sandboxed build has. Every file Leiningen downloads lands in
that repository. Maven Resolver records which repository each file came
from, and the POM Leiningen writes gives each repository its URL, so each
file becomes a lockfile entry with its URL and hash.

The lock is current while `project.clj` and `profiles.clj` are unchanged
and the Leiningen version is the same. `lein-purifier lock` leaves a
current lockfile alone, and `--force` relocks regardless. `--no-uberjar`
leaves the uberjar out of the lock and the build.

## Use

Lock the project from its root and commit the lockfile:

```zsh
nix run github:nix-purifiers/lein-purifier -- lock
```

The flake's `overlays.default` adds `buildLeinProject` to a package set,
and a package written for `callPackage` takes it by name, like any other
builder:

```nix
# package.nix
{ buildLeinProject }:
(buildLeinProject { src = ./.; }).package
```

```nix
{
  inputs.lein-purifier.url = "github:nix-purifiers/lein-purifier";
  inputs.nixpkgs.follows = "lein-purifier/nixpkgs";

  outputs = { nixpkgs, lein-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          lein-purifier.overlays.default
          (final: prev: { hello = final.callPackage ./package.nix { }; })
        ];
      };
    in
    {
      packages.${system}.default = pkgs.hello;
    };
}
```

`nix build` then builds the project. The builder takes what it needs from
the package set, so `buildLeinProject.override` or an overlay replaces any
of it. `nix/lib/build-lein-project.nix` documents the arguments: `jdk`
(the default is the headless JDK of the major version the lock was made
with), `fetchurl` (for credentials or mirrors), `doCheck` (runs
`lein test`) and `srcFilter`. The package lists its files in
`artifacts`, such as `artifacts."hello-1.0.0-standalone.jar"`, which are
known from the lockfile before the build runs.

We recommend following the nixpkgs input of lein-purifier, as above. The
builder uses the Leiningen of the package set, and it refuses a lockfile
made with another Leiningen version, because each version adds its own
nREPL dependencies to every project.

### Interactive mode

```zsh
nix run github:nix-purifiers/lein-purifier -- lein test
```

`lein-purifier lein` fetches the locked files through Nix, keeps them
alive with one GC root under `target/lein-purifier`, and runs Leiningen
offline on a local repository made of links to them. Your own Leiningen
profiles stay in effect. When the lockfile is out of date, it warns and
runs Leiningen the usual way until `lein-purifier lock` renews it.

## Limits

- **Fixed versions only.** Version ranges and SNAPSHOT dependencies need
  repository metadata that changes over time, so the lock run fails when
  Leiningen resolves any.
- **Repositories the project declares.** Each locked file must come from
  a repository in the project's `:repositories`. A mirror configured in a
  profile fails the lock run with a list of the files it served.
- **One project.** Multi-project setups such as lein-monolith or lein-sub
  are not supported.
- **No user profile in the build.** The lock run and the sandboxed build
  ignore `~/.lein/profiles.clj`, so a project that needs something from it
  has to declare it in `project.clj` or `profiles.clj`.

## Credit

The purifier idea was inspired by nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo).

## License

MIT
