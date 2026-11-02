#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Native Nix input selection and runtime publication for ordinary Maven clients."""
from pathlib import Path
import json, os, shutil, subprocess, tempfile

root = Path(__file__).resolve().parent.parent
system = subprocess.check_output(['nix', 'eval', '--impure', '--raw', '--expr',
    'builtins.currentSystem'], text=True).strip()
snapshot = json.loads(subprocess.check_output(['nix', 'flake', 'metadata', '--json',
    '--no-write-lock-file', 'path:'+str(root)], text=True))['path']
with tempfile.TemporaryDirectory(prefix='lein-native-composition-') as temporary:
    temporary = Path(temporary)
    subprocess.run(['nix-store', '--add-root', str(temporary/'source'), '--realise', snapshot], check=True)
    package = subprocess.check_output(['nix', 'build', str(root)+'#default', '--print-out-paths',
        '--out-link', str(temporary/'cli')], text=True).strip().splitlines()[-1]
    cli = Path(package)/'bin/lein-purifier'
    expression = """let
      f = builtins.getFlake ("path:" + builtins.getEnv "COMPOSITION_FLAKE");
      p = f.inputs.nixpkgs.legacyPackages.${builtins.currentSystem};
    in p.runCommand "composition-downstream-tools" {} ''
      mkdir -p "$out/bin"
      ln -s ${p.maven}/bin/mvn "$out/bin/mvn"
      ln -s ${p.jdk21_headless.home} "$out/jdk"
    '' """
    tools = Path(subprocess.check_output(['nix', 'build', '--impure', '--print-out-paths',
        '--out-link', str(temporary/'tools'), '--expr', expression], text=True,
        env=dict(os.environ, COMPOSITION_FLAKE=str(root))).strip())
    for case, attribute, supplied in (
        ('direct', 'provider', 'org/clojure/data.json/'),
        ('transitive', 'transitiveProvider', 'org/apache/commons/commons-lang3/'),
    ):
        workspace = temporary/case
        shutil.copytree(root/'tests/fixtures/hello', workspace)
        (workspace/'lein-purifier.lock.json').unlink(missing_ok=True)
        if case == 'transitive':
            definition = workspace/'project.clj'
            definition.write_text(definition.read_text().replace('[hiccup "1.0.5"]]',
                '[hiccup "1.0.5"] [org.apache.commons/commons-text "1.13.0"]]'))
            source = workspace/'src/hello/core.clj'
            source.write_text(source.read_text().replace('(defn greeting [who]', '''(defn greeting [who]
  (assert (= "Nix" (org.apache.commons.lang3.StringUtils/purifierIdentity)))
  (assert (= "Nix" (org.apache.commons.text.WordUtils/capitalizeFully "nix")))'''))
        repository = temporary/(case+'-published')
        lein_home = temporary/(case+'-lein-home')
        lein_home.mkdir()
        (lein_home/'profiles.clj').write_text('{:user {:deploy-repositories [["test" {:url '
            +json.dumps(repository.as_uri())+' :sign-releases false}]]}}\n')
        env = dict(os.environ, LEIN_HOME=str(lein_home),
                   LEIN_PURIFIER_CENTRAL_MIRROR='https://repo.maven.apache.org/maven2/')
        def run(*args):
            subprocess.run([str(x) for x in args], cwd=workspace, env=env, check=True)
        reference = 'path:'+snapshot+'#checks.'+system+'.composition.'+attribute
        run(cli, 'lock', '--input', reference)
        locked = json.loads((workspace/'lein-purifier.lock.json').read_text())
        assert len(locked['projectInputs']) == 1
        assert not any(entry['path'].startswith(supplied) for entry in locked['artifacts'])
        run(cli, 'prefetch')
        run(cli.parent/'lein', 'test')
        run(cli.parent/'lein', 'pom')
        shutil.rmtree(workspace/'target/classes', ignore_errors=True)
        run(cli, 'publish', 'test')
        assert not (workspace/'target/classes').exists(), 'publishing compiled the working tree'
        pom = next((repository/'example/hello').glob('*/*.pom'))
        assert '-nix-' in pom.parent.name
        if case == 'transitive':
            assert next((repository/'org/apache/commons/commons-text').glob('*/*-nix-*.jar')).is_file()
        downstream = temporary/(case+'-downstream')
        source = downstream/'src/main/java/Downstream.java'
        source.parent.mkdir(parents=True)
        origin = '''String location = Thread.currentThread().getContextClassLoader()
          .getResource("clojure/data/json.clj").toString();
          if (!location.contains("-nix-")) throw new AssertionError(location);''' if case == 'direct' else '''
          for (String name : new String[]{"org.apache.commons.lang3.StringUtils", "org.apache.commons.text.WordUtils"}) {
            String location = Class.forName(name).getProtectionDomain().getCodeSource().getLocation().toString();
            if (!location.contains("-nix-")) throw new AssertionError(location);
          }'''
        source.write_text('''public final class Downstream { public static void main(String[] args) throws Exception {
  Class.forName("hello.core").getMethod("main", String[].class).invoke(null, (Object)new String[]{"nix"});
'''+origin+'\nSystem.out.println("ORDINARY MAVEN PASSED"); } }')
        (downstream/'pom.xml').write_text(f'''<project><modelVersion>4.0.0</modelVersion>
          <groupId>example</groupId><artifactId>downstream</artifactId><version>1</version>
          <properties><maven.compiler.release>21</maven.compiler.release></properties>
          <repositories><repository><id>projected</id><url>{repository.as_uri()}</url></repository></repositories>
          <dependencies><dependency><groupId>example</groupId><artifactId>hello</artifactId>
          <version>{pom.parent.name}</version></dependency></dependencies></project>''')
        plain = dict(os.environ, JAVA_HOME=str(tools/'jdk'))
        subprocess.run([str(tools/'bin/mvn'), '-B', '-Dmaven.repo.local='+str(temporary/'ordinary-m2'),
            'package', 'dependency:build-classpath', '-Dmdep.outputFile=classpath'], cwd=downstream, env=plain, check=True)
        subprocess.run([str(tools/'jdk/bin/java'), '-cp', str(downstream/'target/classes')+os.pathsep
            +(downstream/'classpath').read_text().strip(), 'Downstream'], cwd=downstream, env=plain, check=True)
        print('LEIN '+case.upper()+' NATIVE, PURE PUBLICATION, AND ORDINARY MAVEN PASSED', flush=True)
