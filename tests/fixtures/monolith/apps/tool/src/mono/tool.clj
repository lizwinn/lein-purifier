(ns mono.tool
  (:require [mono.core :refer [describe]])
  (:gen-class))

(defn -main [& _]
  (println (describe "mono-tool")))
