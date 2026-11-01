;; SPDX-License-Identifier: MIT
;;
;; The Leiningen init file of a lock run. `lein-purifier lock` copies it
;; into the empty Leiningen home of the run, and Leiningen loads it at
;; startup, before it reads the project or resolves its plugins.
;;
;; It does two things:
;;
;; - When LEIN_PURIFIER_TRANSFER_LOG names a file, every download that
;;   Maven Resolver completes is appended to it as a line of the
;;   repository URL, the resource name, the local file and the directory
;;   Leiningen runs in, separated by tabs. The directory resolves a
;;   relative `file:` repository URL. The URL is the one the file actually came from, so a file that
;;   a mirror served is recorded with the URL of the mirror.
;; - It defines the task `purifier-info`, which prints what the lock needs
;;   to know about the project, one tab-separated record per line.

(require 'cemerick.pomegranate.aether)

(when-let [log (System/getenv "LEIN_PURIFIER_TRANSFER_LOG")]
  (let [lock (Object.)]
    (alter-var-root
     #'cemerick.pomegranate.aether/resolve-dependencies
     (fn [resolve]
       (fn [& args]
         (let [options (apply hash-map args)
               listener (:transfer-listener options)
               record (fn [{:keys [type method resource] :as event}]
                        (when (and (= type :succeeded) (= method :get))
                          (locking lock
                            (spit log
                                  (str (:repository resource) "\t"
                                       (:name resource) "\t"
                                       (:file resource) "\t"
                                       (System/getProperty "user.dir") "\n")
                                  :append true)))
                        (when (fn? listener)
                          (listener event)))]
           (apply resolve (apply concat (assoc options :transfer-listener record)))))))))

(ns leiningen.purifier-info
  "Prints the identity, the dependencies and the subprojects of the project.")

(defn- line [& fields]
  (println (apply str (interpose "\t" fields))))

(defn purifier-info
  "Prints one record per line: `project` with the group, name and version;
  `main` with the :main namespace, when the project has one; `dependency`
  with the group and name of each dependency; and `subproject` with each
  directory or glob that lein-sub (:sub) or lein-monolith
  (:monolith :project-dirs) names."
  [project]
  (line "project" (:group project) (:name project) (:version project))
  (when-let [main (:main project)]
    (line "main" main))
  (doseq [[dependency] (:dependencies project)]
    (line "dependency" (or (namespace dependency) (name dependency)) (name dependency)))
  (doseq [directory (concat (:sub project) (get-in project [:monolith :project-dirs]))]
    (line "subproject" directory)))

(in-ns 'user)
