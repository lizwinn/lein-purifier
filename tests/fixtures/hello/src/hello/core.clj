(ns hello.core
  (:require [clojure.data.json :as json]
            [hiccup.core :refer [html]])
  (:gen-class))

(defn greeting [who]
  {:json (json/write-str {:hello who})
   :html (html [:p "Hello, " who])})

(defn -main [& args]
  (let [{:keys [json html]} (greeting (or (first args) "world"))]
    (println json)
    (println html)))
