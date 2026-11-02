# SPDX-License-Identifier: MIT
{
  pkgs,
  build,
  purifier,
}:
let
  original = builtins.fromJSON (builtins.readFile ./fixtures/hello/lein-purifier.lock.json);
  upstream = builtins.head (
    builtins.filter (
      entry: entry.path == "org/clojure/data.json/2.5.0/data.json-2.5.0.jar"
    ) original.artifacts
  );
  upstreamJar = purifier.fetchEntry { inherit pkgs; } upstream;
  provider =
    pkgs.runCommand "lein-json-provider"
      {
        passthru.projections = purifier.jvmProjections {
          repository = provider;
          inherit (pkgs) runCommand python3;
        };
      }
      ''
        directory=$out/org/clojure/data.json/0.0.1
        mkdir -p "$directory"
        cp ${upstreamJar} "$directory/data.json-0.0.1.jar"
        cat > "$directory/data.json-0.0.1.pom" <<'POM'
        <project xmlns="http://maven.apache.org/POM/4.0.0">
          <modelVersion>4.0.0</modelVersion><groupId>org.clojure</groupId>
          <artifactId>data.json</artifactId><version>0.0.1</version>
        </project>
        POM
      '';
  withoutProvided = original // {
    artifacts = builtins.filter (
      entry: !(pkgs.lib.hasPrefix "org/clojure/data.json/" entry.path)
    ) original.artifacts;
  };
  lockFile = builtins.toFile "lein-purifier.lock.json" (
    builtins.toJSON (
      withoutProvided
      // {
        integrity = import ../nix/lib/integrity.nix withoutProvided;
      }
    )
  );
  consumer = build {
    src = ./fixtures/hello;
    inherit lockFile;
    projectDependencies = [ provider ];
  };
in
pkgs.runCommand "lein-nix-composition"
  {
    nativeBuildInputs = [ pkgs.python3 ];
    passthru = { inherit provider consumer; };
  }
  ''
    test -d ${consumer.tests}
    ${consumer.packages.hello}/bin/hello > result
    grep -qx '{"hello":"world"}' result
    export CATALOG=${provider.projections.maven.catalog}
    export POM=${consumer.packages.hello}/share/java/hello-1.0.0.pom
    python - <<'PY'
    import json, os, xml.etree.ElementTree as ET
    catalog = json.load(open(os.environ['CATALOG']))
    selected = next(m['version'] for m in catalog['modules'] if m['name'] == 'data.json')
    root = ET.parse(os.environ['POM']).getroot()
    ns = {'m': root.tag.split('}')[0][1:]}
    dependency = next(d for d in root.findall('m:dependencies/m:dependency', ns)
                      if d.findtext('m:artifactId', namespaces=ns) == 'data.json')
    assert dependency.findtext('m:version', namespaces=ns) == selected
    PY
    touch $out
  ''
