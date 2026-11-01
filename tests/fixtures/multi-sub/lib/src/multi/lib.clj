(ns multi.lib)

(defn shout [s]
  (str (.toUpperCase ^String s) "!"))
