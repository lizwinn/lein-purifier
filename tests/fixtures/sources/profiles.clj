;; The dev profile, which Leiningen applies by default, sends every request
;; for Maven Central to a mirror of it. The lock records the URL of the
;; mirror for each file it served.
{:dev {:mirrors {"central" {:name "google-maven-central"
                            :url "https://maven-central.storage-download.googleapis.com/maven2/"}}}}
