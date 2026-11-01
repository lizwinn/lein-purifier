(defproject example/multi-sub "1.0.0"
  :description "A lein-purifier test fixture: a lein-sub project whose application depends on its library."
  :license {:name "MIT"}
  :plugins [[lein-sub "0.3.0"]]
  ;; The application comes first, so the lock has to find the build order.
  :sub ["app" "lib"])
