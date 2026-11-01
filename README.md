# lein-purifier

A command and a Nix library that build
[Leiningen](https://leiningen.org) projects in the Nix sandbox. The
command records the files Leiningen wants to download in a lockfile, and
Nix builds the project from that lockfile, offline. You commit the
lockfile, and no generated Nix files.

lein-purifier is one of the [nix-purifiers](https://nix-purifiers.github.io).

- **A lockfile.** `lein-purifier lock` writes `lein-purifier.lock.json`
  at the project root. It holds every file the build downloads, by the URL
  it came from and its SHA-256, and the content of the repository metadata
  Leiningen read. It also names each project of the build, its main class
  and the jars it produces, so Nix knows every output when it evaluates.
- **Sandboxed builds.** `buildLeinProject` turns a project and its
  lockfile into one package per project, with the jar, the uberjar and the
  POM in `share/java`, and a launcher in `bin` for a project with `:main`.
- **Interactive Leiningen on the locked downloads.** `lein-purifier lein`
  runs Leiningen offline, with a local Maven repository that holds exactly
  the locked files.
- **Deploying what Nix built.** `lein-purifier deploy` builds the packages
  with Nix and deploys their jar and POM with `lein deploy`.

## How the lock is made

`lein-purifier lock` copies the project to a temporary directory and runs
`lein with-profile +test deps` and `lein do jar, uberjar, pom` there, with
an empty local Maven repository and no user profile. That is the
environment a sandboxed build has. A Leiningen init file logs every
download Maven Resolver completes, with the URL it came from, so a file a
mirror served is locked with the URL of the mirror.

The lock covers:

- dependencies and plugins from any Maven repository, Maven Central and
  Clojars included, and from mirrors that the project or its
  `profiles.clj` configures;
- the dependencies of the `test` and `uberjar` profiles, and the nREPL
  dependencies Leiningen adds to every project;
- version ranges and SNAPSHOT versions. Maven Resolver picks those from
  repository metadata, whose content changes over time at its URL, so the
  lockfile holds the content the lock run read, and the timestamped
  SNAPSHOT files are ordinary downloads. The build resolves to the same
  versions the lock run did;
- repositories inside the project, such as `:repositories [["local"
  "file:repository"]]`. Their files are not downloads: the build takes
  them from the project source;
- projects with subprojects, which lein-sub names in `:sub` and
  lein-monolith in its `:project-dirs`. The lock runs each subproject in
  dependency order and installs it into the local repository, and Nix
  builds one package per subproject, with the packages of the
  subprojects it depends on in its local repository.

The lock is current while every `project.clj` and `profiles.clj` of the
build is unchanged and the Leiningen version is the same.
`lein-purifier lock` leaves a current lockfile alone, and `--force`
relocks regardless. `--no-uberjar` leaves the uberjars out of the lock and
the build.

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

`nix build` then builds the project. For a build with subprojects, take
each one from `packages`, such as `(buildLeinProject { src = ./.; }).packages.my-app`.
A package lists its jars in `artifacts`, such as
`artifacts."hello-1.0.0-standalone.jar"`, which are known from the
lockfile before the build runs.

The builder takes what it needs from the package set, so
`buildLeinProject.override` or an overlay replaces any of it.
`nix/lib/build-lein-project.nix` documents the arguments: `jdk` (the
default is the headless JDK of the major version the lock was made with),
`fetchurl` (for credentials or mirrors), `doCheck` (runs `lein test`) and
`srcFilter`.

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
offline in the current directory, on a local repository made of links to
them. Your own Leiningen profiles stay in effect. In a build with
subprojects, `lein-purifier lein install` in a library makes it available
to the projects that depend on it, as `lein install` does. When the
lockfile is out of date, the command warns and runs Leiningen the usual
way until `lein-purifier lock` renews it.

### Deploying

```zsh
nix run github:nix-purifiers/lein-purifier -- deploy clojars
```

`lein-purifier deploy REPOSITORY [NAME...]` builds each package with Nix,
from the nixpkgs of the command, and runs `lein deploy` with its jar and
POM, so nothing is compiled outside the sandbox. The repository, its
credentials and signing work as they do for `lein deploy`.

## Behind an authenticating proxy

Behind an HTTP proxy that requires Basic authentication, the JVM refuses
the proxy by default, and Leiningen reports "Checksum validation failed,
no checksums available". `lein-purifier` keeps the caller's
`LEIN_JVM_OPTS`, so allowing Basic authentication fixes it:

```zsh
LEIN_JVM_OPTS='-Djdk.http.auth.tunneling.disabledSchemes= -Djdk.http.auth.proxying.disabledSchemes=' lein-purifier lock
```

## Limits

Each of these follows from how Leiningen or the Nix sandbox works.

- **Only Maven repositories.** Leiningen resolves dependencies from Maven
  repositories only. Git dependencies and URL tarballs exist only through
  third-party plugins such as lein-git-down, which fetch with code of
  their own, outside Maven Resolver, so the lock run cannot see those
  downloads.
- **`file:` repositories inside the project.** A `file:` repository
  outside the project is a path on one machine, which the sandbox cannot
  read, so the lock run stops when the project uses one.
- **No checkouts.** Leiningen checkouts are links from `checkouts/` to
  other projects on the same machine, so the lock run and the sandboxed
  build leave them out. The interactive mode keeps them, since it runs in
  the project itself.
- **No user profile in the lock or the build.** The lock run and the
  sandboxed build ignore `~/.lein/profiles.clj`, so a project that needs
  something from it has to declare it in `project.clj` or `profiles.clj`.
- **One platform per lock.** Leiningen selects the same artifacts on every
  platform, and the lockfile evaluates on every system Nix supports. A
  dependency whose POM activates a profile by operating system or
  architecture is the exception: the lock holds what the platform of the
  lock run resolved.

## Credit

lein-purifier follows the design of
[sbt-nix-backend](https://github.com/clhodapp/sbt-nix-backend), which is
becoming sbt-purifier: a lock run in the sandbox environment, a lockfile of
downloads and outputs, sandboxed builds, an offline interactive mode and
a publish step from what Nix built. The purifier idea was inspired by
nixcloud's [cargo (libnix)](https://github.com/nixcloud/cargo).

## License

MIT
