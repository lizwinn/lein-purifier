(defproject example/mono-tool "1.0.0"
  :description "The application of the monolith fixture. It takes its license from the metaproject."
  :plugins [[lein-monolith "1.11.1"]]
  :middleware [lein-monolith.plugin/middleware]
  :monolith/inherit true
  :dependencies [[org.clojure/clojure "1.12.0"]
                 [example/mono-core "1.0.0"]]
  :main mono.tool
  :profiles {:uberjar {:aot :all}})
