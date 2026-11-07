# usage: build/build-updater.sh configures this for x86_64 and builds the updater.
cmake_minimum_required(VERSION 3.16)
project(JdkUpdater LANGUAGES OBJC)

find_package(MavericksShipyard REQUIRED)
# spec: build/build-updater.sh -- clang22, like everything else this repo compiles
set(MAVERICKS_REQUIRE_APPLECLANG OFF)
include(Mavericks)
include(MavericksSparkle)

mavericks_resolve_version(JDK_VERSION)
string(REGEX REPLACE "^([0-9]+)\\..*$" "\\1" JDK_LINE "${JDK_VERSION}")
if(NOT JDK_LINE MATCHES "^[0-9]+$")
  message(FATAL_ERROR "cannot derive the JDK line from the version '${JDK_VERSION}'")
endif()

mavericks_add_updater_app(
  PRODUCT jdk${JDK_LINE}
  PRODUCT_NAME "Mavericks JDK ${JDK_LINE}"
  ICON "${CMAKE_SOURCE_DIR}/updater/jdk${JDK_LINE}-updater.icns"
  VERSION "${JDK_VERSION}"
  LOG_PREFIX "MavJdkUpdater"
  CONFIRM_TITLE "Mavericks JDK ${JDK_LINE} updated"
  CONFIRM_BODY "JDK ${JDK_LINE} in /usr/local/mavergreen/jdk${JDK_LINE} was updated."
  RELAUNCH_MARKER "/tmp/.mavericks-jdk${JDK_LINE}-updater-relaunched"
)
