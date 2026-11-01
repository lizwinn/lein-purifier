(ns sources.core
  (:require [clojure.data.json :as json]
            [clojure.java.io :as io]
            [greeting.core :refer [greet]])
  (:gen-class))

(defn -main [& _]
  (println (json/write-str {:greeting (greet "sources")
                            ;; leiningen/shell.clj is in the SNAPSHOT jar.
                            :snapshot (some? (io/resource "leiningen/shell.clj"))})))
