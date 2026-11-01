# SPDX-License-Identifier: MIT
#
# The store path of a lockfile entry. An entry is one of two kinds:
#
#   { path, url, mirrors, hash }  a file downloaded from `url`, or else
#                                 from one of the fallback URLs `mirrors`
#   { path, contents }            a file with this content, which is
#                                 repository metadata whose content at its
#                                 URL changes over time
#
# By default a file entry is a fixed-output derivation on Nix's built-in
# fetcher (the same derivation <nix/fetchurl.nix> makes), so neither the
# interactive mode nor a sandboxed build needs nixpkgs to download. A
# fixed-output store path depends only on its name and hash, so the
# default fetcher, builtins.fetchurl and nixpkgs' fetchurl produce the same
# paths.
#
# `fetchurl`, when given, replaces the built-in fetcher. It is called with
# { name, urls, hash } and is the place for credentials (nixpkgs' fetchurl
# takes `netrcPhase`) or mirrors.
{
  lock,
  fetchurl ? null,
}:
entry:
let
  name = lock.artifactName entry;
  urls = [ entry.url ] ++ entry.mirrors;
in
if entry ? contents then
  builtins.toFile name entry.contents
else if fetchurl != null then
  fetchurl {
    inherit name urls;
    inherit (entry) hash;
  }
else
  derivation {
    inherit name urls;
    builder = "builtin:fetchurl";
    system = "builtin";
    inherit (entry) url;
    outputHash = entry.hash;
    outputHashAlgo = "sha256";
    outputHashMode = "flat";
    unpack = false;
    executable = false;
    preferLocalBuild = true;
    impureEnvVars = [
      "http_proxy"
      "https_proxy"
      "ftp_proxy"
      "all_proxy"
      "no_proxy"
    ];
  }
