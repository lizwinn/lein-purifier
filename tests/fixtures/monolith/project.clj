(defproject example/monolith "MONOLITH"
  :description "A lein-purifier test fixture: a lein-monolith metaproject with a library and an application."
  :license {:name "MIT"}
  :plugins [[lein-monolith "1.11.1"]]
  ;; Subprojects that set :monolith/inherit take the license from here.
  :monolith {:inherit [:license]
             :project-dirs ["libs/*" "apps/*"]})
