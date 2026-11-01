(defproject example/multi-app "1.0.0"
  :description "The application of the multi-sub fixture, which uses its library."
  :license {:name "MIT"}
  :dependencies [[org.clojure/clojure "1.12.0"]
                 [example/multi-lib "1.0.0"]]
  :main multi.app
  :profiles {:uberjar {:aot :all}})
