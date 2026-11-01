(defproject example/sources "0.1.0-SNAPSHOT"
  :description "A lein-purifier test fixture: dependencies from a version range, a SNAPSHOT and a repository inside the project."
  :license {:name "MIT"}
  :repositories [["in-project" {:url "file:repository" :snapshots false}]]
  :dependencies [[org.clojure/clojure "1.12.0"]
                 ;; Resolves to 2.5.0, the highest version in the range.
                 [org.clojure/data.json "[2.4.0,2.5.0]"]
                 ;; A SNAPSHOT from 2014 on Clojars, which a release replaced.
                 [lein-shell "0.4.0-SNAPSHOT"]
                 ;; From the repository inside the project.
                 [example/greeting "1.0.0"]]
  :main sources.core
  :profiles {:uberjar {:aot :all}})
