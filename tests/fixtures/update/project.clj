(defproject example/update "1.0.0"
  :description "A lein-purifier test fixture: a version range whose lockfile pins an older version than the range allows."
  :license {:name "MIT"}
  :dependencies [[org.clojure/clojure "1.12.0"]
                 ;; The lockfile keeps 2.4.0; `lein-purifier update` moves it to 2.5.0.
                 [org.clojure/data.json "[2.4.0,2.5.0]"]])
