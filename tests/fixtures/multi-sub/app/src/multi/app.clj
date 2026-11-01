(ns multi.app
  (:require [multi.lib :refer [shout]])
  (:gen-class))

(defn -main [& _]
  (println (shout "multi-sub")))
