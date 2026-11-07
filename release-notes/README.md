# Release notes

The generator (`release-notes.sh`, from shipyard) writes the notes file for every release. That one
file becomes both the GitHub Release body and the Sparkle appcast `<description>`.

A file here, named `<full-version>.md` (e.g. `25.0.4.1-mavericks.1.md`), is OPTIONAL hand-written prose
for that one release, inserted verbatim after the generated title. It must NOT start with its own
heading: the generator already emits the title.
