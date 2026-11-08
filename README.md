# Java 25 for Mavericks

Java (based on OpenJDK) for Mac OS X 10.9 Mavericks.

## GUI included

AWT, Swing and Java2D work: Java programs open native-looking windows, put their menus in the menu
bar at the top of the screen, and draw through OpenGL (Mac OS X 10.9 has no Metal). Opening a window
needs someone logged in at the Mac.

How the GUI is tested:

- **By hand, on real 10.9:** a Mac Pro (Late 2013) running 10.9.5, with SwingSet2's demos, both
  look-and-feels, and the native print dialog's PDF button.
- **By GuiSmoke, on real 10.9 under a console login:** `tests/smoke-gui.sh` opens a window and checks
  painting, the screen menu bar, resizing, full screen, typing, fonts, the clipboard, drag and drop,
  the Dock badge, `Desktop.open` and printing to a file.
- **Not in CI:** the 10.9 guest that CI installs and tests in has no window server, so
  `smoke-gui.sh` skips there and says so. CI still checks every GUI library against 10.9 (the compat
  guard) and that none of them uses Metal.

## Limitations

- **VoiceOver:** on 10.9 it reads Java's menus and window titles but cannot reach the controls inside
  a Swing window.
- **Printing to a file:** use the PDF button in the Mac print dialog. Java's own cross-platform print
  dialog (`JTable`'s Print uses it) may send a Print to File job to your printer instead: we read
  that in the source but have not tried it.
