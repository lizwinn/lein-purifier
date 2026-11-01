(defproject example/hello "1.0.0"
  :description "A lein-purifier test fixture: an application with a dependency from Maven Central and one from Clojars."
  :license {:name "MIT"}
  :dependencies [[org.clojure/clojure "1.12.0"]
                 [org.clojure/data.json "2.5.0"]
                 [hiccup "1.0.5"]]
  :plugins [[lein-shell "0.5.0"]]
  :main hello.core
  :profiles {:uberjar {:aot :all}
             :test {:dependencies [[org.clojure/test.check "1.1.1"]]}})
