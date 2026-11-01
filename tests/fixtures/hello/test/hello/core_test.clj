(ns hello.core-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.test.check.generators :as gen]
            [hello.core :refer [greeting]]))

(deftest greets
  (is (= "{\"hello\":\"you\"}" (:json (greeting "you"))))
  (is (= "<p>Hello, you</p>" (:html (greeting "you")))))

(deftest generators-load
  (is (string? (gen/generate gen/string-alphanumeric))))
