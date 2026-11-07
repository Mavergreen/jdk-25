#!/bin/sh
# platform: host-agnostic
#   usage: upstream-release-notes-url.sh <upstream-version>
#          Prints the OpenJDK bug system's list of the issues fixed in that jdk25u release (its
#          fixVersion, such as 25.0.5 or 25.0.5.0.3): jdk25u publishes no release-notes page of its
#          own per update, and the JDK Updates wiki links only these JBS queries.
# spec: tests/upstream-release-notes-url-test.sh
set -eu
[ "$#" -eq 1 ] || { echo "usage: upstream-release-notes-url.sh <upstream-version>" >&2; exit 2; }
v="$1"
refuse() { echo "upstream-release-notes-url: '$v' is not a jdk25u version (25.<interim>.<update>, then up to two more numeric parts)" >&2; exit 2; }
case "$v" in ''|*[!0-9.]*|.*|*.|*..*|25.*.*.*.*.*) refuse ;; esac
case "$v" in 25.*.*) : ;; *) refuse ;; esac
printf 'https://bugs.openjdk.org/issues/?jql=project%%20%%3D%%20JDK%%20AND%%20fixVersion%%20%%3D%%20%s\n' "$v"
