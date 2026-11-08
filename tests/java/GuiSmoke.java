/*
 * GuiSmoke: the headful smoke tests/smoke-gui.sh runs on Mac OS X 10.9 under a console login.
 * Each step prints "ok <step>" or "FAIL <step>: <why>"; the first failure ends the run with exit 1,
 * and a watchdog ends a hung run with exit 2 (after 300 s). Steps, in order:
 *   headful    GraphicsEnvironment is not headless and Java2D's pipeline is OpenGL (patches/0015);
 *   frame      a JFrame with a JMenuBar, a JTextField and a custom-painted JPanel is showing, and
 *              the application is asked to the front (Desktop.requestForeground);
 *   screenmenubar  with apple.laf.useScreenMenuBar=true (set first thing), Aqua gave the frame an AWT
 *              MenuBar (com.apple.laf.ScreenMenuBar, which AppKit shows as the screen's menu bar)
 *              holding the one menu, and the JMenuBar takes no height in the window; with
 *              -Dguismoke.shots=DIR it also saves DIR/screenmenubar.png, the screen's top strip, to
 *              check by eye that the menu is in the screen's menu bar;
 *   paint      the panel's paintComponent ran;
 *   pixel      Robot.getPixelColor at the panel's centre reads green over red and blue; repainted with
 *              a red over green and blue, it reads red; back to green, it reads the first value again;
 *   resize     the frame grows, the panel follows, and the pixel at its new centre reads that value;
 *   fullscreen the frame becomes the screen's full-screen window, fills the screen, and comes back;
 *   type       Robot types "mvk" into the focused text field;
 *   fonts      CoreText's font families include Lucida Grande, which resolves as itself (not Dialog),
 *              and "Hello" in it draws ink off screen and in the frame's label; with shots, hello.png;
 *   clipboard  only on an empty or plain-text clipboard (osascript's clipboard info), which it puts
 *              back exactly: a string set on it reads back in Java and through /usr/bin/pbpaste (the
 *              AppKit pasteboard); any other content is left alone and the step prints "skip";
 *   dnd        Robot drags the selected "dragme" from one text field and drops it on another;
 *   badge      Taskbar supports a badge and sets "17" without error, then clears it; with shots, dock.png
 *              shows it, unless the Dock autohides, which the shot line then says;
 *   desktop    Desktop.open of a new empty folder opens a Finder window on exactly that folder
 *              (LaunchServices, patches/0006), not its parent, within 60 s, as /usr/bin/osascript reads
 *              each window's target; a window that comes in the 15 s after that fails the step by name
 *              and is closed; the step closes every window it opened, even after a failure, before it
 *              deletes the folder. open and browse are reported apart, and a failing open does not
 *              keep browse from running. Desktop.browse sends any URL to the default browser (CDesktopPeer asks
 *              LaunchServices which app opens https:), so by default the step only requires BROWSE to
 *              be supported; Java has no public API that names the default browser. With
 *              -Dguismoke.browse=true it browses a small file: page and prints what to look for;
 *   print      PrinterJob prints a page to a PostScript file through a StreamPrintService, which never
 *              reaches a printer queue or a dialog; the page's Printable ran, and the file starts
 *              %!PS-Adobe;
 *   close      a WINDOW_CLOSING event disposes the frame, and windowClosed arrives.
 * With -Dguismoke.hold=true it runs none of these: it opens one frame for a person to try with
 * VoiceOver (a Smoke menu in the screen's menu bar, a labelled text field, a "Say hello" button and
 * the label it sets) and stays open, with no watchdog and no Robot, until the window is closed or
 * the application quits.
 * Robot reads the screen in the display's colour space, not the sRGB the panel paints in: on the 10.9
 * box sRGB #219e5b read back as #009d5b. So the first read-back is judged by which channel dominates,
 * which a display profile keeps for a saturated colour, and every later one against that first read.
 * A black, unpainted (window grey) or wrongly coloured panel still fails.
 */
import java.awt.Color;
import java.awt.Dimension;
import java.awt.EventQueue;
import java.awt.Graphics;
import java.awt.MenuBar;
import java.awt.GraphicsDevice;
import java.awt.GraphicsEnvironment;
import java.awt.Point;
import java.awt.Rectangle;
import java.awt.Robot;
import java.awt.event.KeyEvent;
import java.awt.event.WindowAdapter;
import java.awt.event.WindowEvent;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import javax.swing.BorderFactory;
import javax.swing.JFrame;
import javax.swing.JMenu;
import javax.swing.JMenuBar;
import javax.swing.JMenuItem;
import javax.swing.JPanel;
import javax.swing.JTextField;
import javax.swing.SwingUtilities;
import javax.swing.WindowConstants;

public class GuiSmoke {
    // Saturated and uncommon, so a display profile keeps the dominant channel and no default
    // background matches by chance; ALT swaps the green and red channels.
    static final Color FILL = new Color(0x21, 0x9e, 0x5b);
    static final Color ALT = new Color(0x9e, 0x21, 0x5b);
    static final int TOLERANCE = 12;
    static final int MARGIN_OVER_RED_OR_GREEN = 60;
    static final int MARGIN_OVER_BLUE = 30;
    static final int DOMINANT_AT_LEAST = 100;
    static volatile Color current = FILL;
    static volatile Color seen;
    static final long STEP_SECONDS = 20;

    static JFrame frame;
    static JPanel panel;
    static JTextField field;
    static JTextField dragSource;
    static JTextField dragTarget;
    static javax.swing.JLabel hello;
    static JMenuBar bar;
    static final CountDownLatch painted = new CountDownLatch(1);
    static final CountDownLatch closed = new CountDownLatch(1);
    static Robot robot;

    static final class Failure extends RuntimeException {
        Failure(String why) { super(why); }
    }

    static final class Skip extends RuntimeException {
        Skip(String why) { super(why); }
    }

    // Runs body, then cleanup whatever happens; the body's own failure is the one reported, with a
    // cleanup failure added to it rather than masking it.
    static void withCleanup(Step body, Step cleanup, String cleanupWhat) throws Exception {
        Throwable first = null;
        try { body.run(); } catch (Throwable t) { first = t; }
        Throwable second = null;
        try { cleanup.run(); } catch (Throwable t) { second = t; }
        if (first != null) {
            if (second != null) {
                throw new Failure(why(first) + "; and " + cleanupWhat + " failed too: " + why(second));
            }
            if (first instanceof Exception e) throw e;
            throw (Error) first;
        }
        if (second != null) throw new Failure(cleanupWhat + " failed: " + why(second));
    }

    static String why(Throwable t) {
        return t instanceof Failure || t instanceof Skip ? t.getMessage() : t.toString();
    }

    interface Step { void run() throws Exception; }

    public static void main(String[] args) throws Exception {
        // Aqua reads it when it installs a JMenuBar's UI, so before any Swing component exists.
        System.setProperty("apple.laf.useScreenMenuBar", "true");
        if (Boolean.getBoolean("guismoke.hold")) {
            hold();
            return;
        }
        Thread watchdog = new Thread(() -> {
            try { Thread.sleep(TimeUnit.SECONDS.toMillis(300)); } catch (InterruptedException e) { return; }
            System.out.println("FAIL watchdog: GuiSmoke did not finish in 300 s");
            System.out.flush();
            Runtime.getRuntime().halt(2);
        });
        watchdog.setDaemon(true);
        watchdog.start();

        step("headful", GuiSmoke::headful);
        step("frame", GuiSmoke::frame);
        step("screenmenubar", GuiSmoke::screenmenubar);
        step("paint", GuiSmoke::paint);
        step("pixel", GuiSmoke::pixel);
        step("resize", GuiSmoke::resize);
        step("fullscreen", GuiSmoke::fullscreen);
        step("type", GuiSmoke::type);
        step("fonts", GuiSmoke::fonts);
        step("clipboard", GuiSmoke::clipboard);
        step("dnd", GuiSmoke::dnd);
        step("badge", GuiSmoke::badge);
        step("desktop", GuiSmoke::desktop);
        step("print", GuiSmoke::print);
        step("close", GuiSmoke::close);
        System.out.println("PASS GuiSmoke");
        System.out.flush();
        System.exit(0);
    }

    // For a person with VoiceOver (Task 18): nothing here times out or moves the pointer.
    static void hold() throws Exception {
        EventQueue.invokeAndWait(() -> {
            JFrame f = new JFrame("GuiSmoke VoiceOver");
            f.setDefaultCloseOperation(WindowConstants.DISPOSE_ON_CLOSE);
            f.addWindowListener(new WindowAdapter() {
                @Override public void windowClosed(WindowEvent e) { System.exit(0); }
            });
            javax.swing.JLabel said = new javax.swing.JLabel("Nobody has said hello yet");
            JTextField name = new JTextField(16);
            javax.swing.JLabel nameLabel = new javax.swing.JLabel("Your name:");
            nameLabel.setLabelFor(name);
            javax.swing.JButton hello = new javax.swing.JButton("Say hello");
            java.awt.event.ActionListener say = e -> said.setText("Hello, " + (name.getText().isBlank() ? "world" : name.getText().trim()));
            hello.addActionListener(say);
            JMenuBar mb = new JMenuBar();
            JMenu menu = new JMenu("Smoke");
            JMenuItem item = new JMenuItem("Say hello");
            item.addActionListener(say);
            menu.add(item);
            mb.add(menu);
            f.setJMenuBar(mb);
            JPanel row = new JPanel();
            row.add(nameLabel);
            row.add(name);
            row.add(hello);
            f.getContentPane().add(row, java.awt.BorderLayout.NORTH);
            f.getContentPane().add(said, java.awt.BorderLayout.SOUTH);
            f.pack();
            f.setLocation(80, 80);
            f.setVisible(true);
        });
        foreground();
        System.out.println("hold: try VoiceOver now. Cmd-F5 turns it on; VO-M (Ctrl-Option-M) goes to the menu bar,"
            + " where the Smoke menu holds \"Say hello\"; in the window, Tab moves from the \"Your name:\" field"
            + " to the \"Say hello\" button, and VO-Space presses it, which changes the label below."
            + " Close the window or quit (Cmd-Q) to end.");
        System.out.flush();
    }

    static void step(String name, Step s) {
        try {
            s.run();
            System.out.println("ok " + name);
        } catch (Skip k) {
            System.out.println("skip " + name + ": " + k.getMessage());
        } catch (Throwable t) {
            String why = t instanceof Failure ? t.getMessage() : t.toString();
            System.out.println("FAIL " + name + ": " + why);
            if (!(t instanceof Failure)) {
                t.printStackTrace(System.out);
            }
            System.out.flush();
            System.exit(1);
        }
    }

    static void require(boolean ok, String why) {
        if (!ok) throw new Failure(why);
    }

    static <T> T onEdt(java.util.concurrent.Callable<T> c) throws Exception {
        AtomicReference<T> r = new AtomicReference<>();
        AtomicReference<Exception> e = new AtomicReference<>();
        EventQueue.invokeAndWait(() -> {
            try { r.set(c.call()); } catch (Exception x) { e.set(x); }
        });
        if (e.get() != null) throw e.get();
        return r.get();
    }

    static void settle() throws Exception {
        robot.waitForIdle();
        robot.delay(300);
        robot.waitForIdle();
    }

    static void headful() throws Exception {
        require(!GraphicsEnvironment.isHeadless(), "GraphicsEnvironment.isHeadless() is true");
        String gc = GraphicsEnvironment.getLocalGraphicsEnvironment().getDefaultScreenDevice()
                .getDefaultConfiguration().getClass().getName();
        require(gc.equals("sun.java2d.opengl.CGLGraphicsConfig"), "the default GraphicsConfiguration is " + gc + ", not OpenGL's");
        robot = new Robot();
        robot.setAutoDelay(40);
    }

    static void frame() throws Exception {
        onEdt(() -> {
            frame = new JFrame("GuiSmoke");
            frame.setDefaultCloseOperation(WindowConstants.DISPOSE_ON_CLOSE);
            frame.addWindowListener(new WindowAdapter() {
                @Override public void windowClosed(WindowEvent e) { closed.countDown(); }
            });
            bar = new JMenuBar();
            JMenu menu = new JMenu("Smoke");
            menu.add(new JMenuItem("Nothing"));
            bar.add(menu);
            frame.setJMenuBar(bar);
            field = new JTextField(12);
            dragSource = new JTextField("dragme", 8);
            dragSource.setDragEnabled(true);
            dragTarget = new JTextField(8);
            hello = new javax.swing.JLabel("Hello");
            hello.setFont(new java.awt.Font("Lucida Grande", java.awt.Font.PLAIN, 36));
            panel = new JPanel() {
                @Override protected void paintComponent(Graphics g) {
                    super.paintComponent(g);
                    g.setColor(current);
                    g.fillRect(0, 0, getWidth(), getHeight());
                    painted.countDown();
                }
            };
            panel.setPreferredSize(new Dimension(320, 200));
            panel.setBorder(BorderFactory.createEmptyBorder());
            JPanel north = new JPanel();
            north.add(field);
            north.add(dragSource);
            north.add(dragTarget);
            frame.getContentPane().add(north, java.awt.BorderLayout.NORTH);
            frame.getContentPane().add(hello, java.awt.BorderLayout.SOUTH);
            frame.getContentPane().add(panel, java.awt.BorderLayout.CENTER);
            frame.pack();
            frame.setLocation(80, 80);
            frame.setVisible(true);
            return null;
        });
        foreground();
        long until = System.nanoTime() + TimeUnit.SECONDS.toNanos(STEP_SECONDS);
        while (!onEdt(() -> frame.isShowing() && panel.isShowing())) {
            require(System.nanoTime() < until, "the frame is not showing after " + STEP_SECONDS + " s");
            Thread.sleep(100);
        }
        settle();
    }

    static void foreground() {
        // A process started from a shell (ssh, a script) is not the active application, and macOS
        // gives focus and the screen's menu bar only to the active one; Desktop asks AppKit for it.
        if (java.awt.Desktop.isDesktopSupported()
                && java.awt.Desktop.getDesktop().isSupported(java.awt.Desktop.Action.APP_REQUEST_FOREGROUND)) {
            java.awt.Desktop.getDesktop().requestForeground(true);
        }
    }

    static void screenmenubar() throws Exception {
        MenuBar mb = onEdt(() -> frame.getMenuBar());
        require(mb != null, "with apple.laf.useScreenMenuBar=true the frame has no AWT MenuBar: the JMenuBar did not go to the screen's menu bar");
        require(mb.getClass().getName().equals("com.apple.laf.ScreenMenuBar"),
            "the frame's MenuBar is a " + mb.getClass().getName() + ", not Aqua's com.apple.laf.ScreenMenuBar");
        require(mb.getMenuCount() == 1 && "Smoke".equals(mb.getMenu(0).getLabel()),
            "the screen menu bar holds " + mb.getMenuCount() + " menu(s)"
            + (mb.getMenuCount() > 0 ? ", the first \"" + mb.getMenu(0).getLabel() + "\"" : "") + ", not the one \"Smoke\"");
        int h = onEdt(() -> bar.getHeight());
        require(h == 0, "the JMenuBar is " + h + " px tall in the window: it is drawn there, not in the screen's menu bar");
        String dir = System.getProperty("guismoke.shots");
        if (dir != null && !dir.isEmpty()) {
            settle();
            Rectangle screen = GraphicsEnvironment.getLocalGraphicsEnvironment().getDefaultScreenDevice()
                .getDefaultConfiguration().getBounds();
            java.io.File shot = new java.io.File(dir, "screenmenubar.png");
            javax.imageio.ImageIO.write(robot.createScreenCapture(
                new Rectangle(screen.x, screen.y, Math.min(screen.width, 800), 44)), "png", shot);
            System.out.println("shot " + shot.getPath() + ": the screen's menu bar should read GuiSmoke, then Smoke");
        }
    }

    static void paint() throws Exception {
        require(painted.await(STEP_SECONDS, TimeUnit.SECONDS), "paintComponent did not run in " + STEP_SECONDS + " s");
        settle();
    }

    static Point panelCentre() throws Exception {
        return onEdt(() -> {
            Point p = panel.getLocationOnScreen();
            return new Point(p.x + panel.getWidth() / 2, p.y + panel.getHeight() / 2);
        });
    }

    static boolean near(Color a, Color b) {
        return Math.abs(a.getRed() - b.getRed()) <= TOLERANCE
            && Math.abs(a.getGreen() - b.getGreen()) <= TOLERANCE
            && Math.abs(a.getBlue() - b.getBlue()) <= TOLERANCE;
    }

    static boolean greenOver(Color c) {
        return c.getGreen() >= DOMINANT_AT_LEAST
            && c.getGreen() - c.getRed() >= MARGIN_OVER_RED_OR_GREEN
            && c.getGreen() - c.getBlue() >= MARGIN_OVER_BLUE;
    }

    static boolean redOver(Color c) {
        return c.getRed() >= DOMINANT_AT_LEAST
            && c.getRed() - c.getGreen() >= MARGIN_OVER_RED_OR_GREEN
            && c.getRed() - c.getBlue() >= MARGIN_OVER_BLUE;
    }

    static String hint(Color got) {
        if (got.getRed() < 16 && got.getGreen() < 16 && got.getBlue() < 16) {
            return "; black is what a locked screen, an asleep display or a run from ssh reads"
                + " (tests/smoke-gui.sh's header)";
        }
        return "";
    }

    interface Judge { boolean ok(Color c); }

    static Color readUntil(Judge judge, String where, String want) throws Exception {
        Point c = panelCentre();
        long until = System.nanoTime() + TimeUnit.SECONDS.toNanos(STEP_SECONDS);
        Color got = robot.getPixelColor(c.x, c.y);
        while (!judge.ok(got)) {
            require(System.nanoTime() < until, "Robot.getPixelColor(" + c.x + ", " + c.y + ") " + where
                + " is " + got + ", not " + want + hint(got));
            robot.delay(200);
            got = robot.getPixelColor(c.x, c.y);
        }
        return got;
    }

    static void repaintWith(Color fill) throws Exception {
        current = fill;
        onEdt(() -> { panel.repaint(); return null; });
        settle();
    }

    static void readBack(String where) throws Exception {
        Color first = seen;
        readUntil(c -> near(c, first), where, "the first read-back " + first + " (within " + TOLERANCE + ")");
    }

    static void pixel() throws Exception {
        seen = readUntil(GuiSmoke::greenOver, "at the panel's centre, painted sRGB " + FILL,
            "green over red by " + MARGIN_OVER_RED_OR_GREEN + " and over blue by " + MARGIN_OVER_BLUE);
        repaintWith(ALT);
        readUntil(GuiSmoke::redOver, "repainted sRGB " + ALT,
            "red over green by " + MARGIN_OVER_RED_OR_GREEN + " and over blue by " + MARGIN_OVER_BLUE);
        repaintWith(FILL);
        readBack("painted sRGB " + FILL + " again");
    }

    static void resize() throws Exception {
        Dimension before = onEdt(() -> panel.getSize());
        onEdt(() -> { frame.setSize(frame.getWidth() + 160, frame.getHeight() + 120); return null; });
        long until = System.nanoTime() + TimeUnit.SECONDS.toNanos(STEP_SECONDS);
        Dimension after = onEdt(() -> panel.getSize());
        while (after.width <= before.width || after.height <= before.height) {
            require(System.nanoTime() < until, "the panel is " + after.width + "x" + after.height
                + " after the frame grew, not larger than " + before.width + "x" + before.height);
            Thread.sleep(100);
            after = onEdt(() -> panel.getSize());
        }
        settle();
        readBack("after the resize");
    }

    static void fullscreen() throws Exception {
        GraphicsDevice gd = GraphicsEnvironment.getLocalGraphicsEnvironment().getDefaultScreenDevice();
        require(gd.isFullScreenSupported(), "the default screen does not support full-screen windows");
        Rectangle screen = gd.getDefaultConfiguration().getBounds();
        Rectangle windowed = onEdt(() -> frame.getBounds());
        onEdt(() -> { gd.setFullScreenWindow(frame); return null; });
        long until = System.nanoTime() + TimeUnit.SECONDS.toNanos(STEP_SECONDS);
        Rectangle b = onEdt(() -> frame.getBounds());
        while (gd.getFullScreenWindow() != frame || !b.equals(screen)) {
            require(System.nanoTime() < until, "full screen: the frame is " + b + ", not the screen's " + screen);
            Thread.sleep(100);
            b = onEdt(() -> frame.getBounds());
        }
        settle();
        readBack("in full screen");
        onEdt(() -> { gd.setFullScreenWindow(null); return null; });
        until = System.nanoTime() + TimeUnit.SECONDS.toNanos(STEP_SECONDS);
        b = onEdt(() -> frame.getBounds());
        while (gd.getFullScreenWindow() != null || b.width >= screen.width) {
            require(System.nanoTime() < until, "leaving full screen: the frame is " + b + ", not about " + windowed);
            Thread.sleep(100);
            b = onEdt(() -> frame.getBounds());
        }
        settle();
    }

    static void type() throws Exception {
        foreground();
        onEdt(() -> { frame.toFront(); field.requestFocusInWindow(); return null; });
        long until = System.nanoTime() + TimeUnit.SECONDS.toNanos(STEP_SECONDS);
        while (!onEdt(() -> field.isFocusOwner())) {
            require(System.nanoTime() < until, "the text field did not get the focus in " + STEP_SECONDS + " s");
            Point f = onEdt(() -> {
                Point p = field.getLocationOnScreen();
                return new Point(p.x + field.getWidth() / 2, p.y + field.getHeight() / 2);
            });
            robot.mouseMove(f.x, f.y);
            robot.mousePress(java.awt.event.InputEvent.BUTTON1_DOWN_MASK);
            robot.mouseRelease(java.awt.event.InputEvent.BUTTON1_DOWN_MASK);
            robot.delay(300);
        }
        for (int k : new int[] {KeyEvent.VK_M, KeyEvent.VK_V, KeyEvent.VK_K}) {
            robot.keyPress(k);
            robot.keyRelease(k);
        }
        until = System.nanoTime() + TimeUnit.SECONDS.toNanos(STEP_SECONDS);
        String text = onEdt(() -> field.getText());
        while (!text.equals("mvk")) {
            require(System.nanoTime() < until, "the text field holds \"" + text + "\", not \"mvk\"");
            Thread.sleep(100);
            text = onEdt(() -> field.getText());
        }
    }

    static void shot(String name, Rectangle r, String see) throws Exception {
        String dir = System.getProperty("guismoke.shots");
        if (dir == null || dir.isEmpty()) return;
        java.io.File f = new java.io.File(dir, name);
        javax.imageio.ImageIO.write(robot.createScreenCapture(r), "png", f);
        System.out.println("shot " + f.getPath() + ": " + see);
    }

    static int count(java.awt.image.BufferedImage img, boolean dark) {
        int n = 0;
        for (int y = 0; y < img.getHeight(); y++) {
            for (int x = 0; x < img.getWidth(); x++) {
                int rgb = img.getRGB(x, y);
                int r = (rgb >> 16) & 0xff, g = (rgb >> 8) & 0xff, b = rgb & 0xff;
                if (dark ? (r < 96 && g < 96 && b < 96) : (r > 160 && g > 160 && b > 160)) n++;
            }
        }
        return n;
    }

    // Dark glyphs on a light ground: a black capture (locked screen, asleep display, ssh) has no light.
    static String ink(java.awt.image.BufferedImage img) {
        int dark = count(img, true), light = count(img, false);
        return dark > 100 && light > 100 ? null : dark + " dark and " + light + " light pixels, not over 100 of each";
    }

    static void fonts() throws Exception {
        String[] families = GraphicsEnvironment.getLocalGraphicsEnvironment().getAvailableFontFamilyNames();
        require(families.length > 0, "CoreText listed no font families");
        require(java.util.Arrays.asList(families).contains("Lucida Grande"),
            "the " + families.length + " font families do not include Lucida Grande, the 10.9 system font");
        java.awt.Font f = new java.awt.Font("Lucida Grande", java.awt.Font.PLAIN, 36);
        require(f.getFamily().equals("Lucida Grande"), "Font(\"Lucida Grande\") resolved to " + f.getFamily());
        java.awt.image.BufferedImage img = new java.awt.image.BufferedImage(200, 60, java.awt.image.BufferedImage.TYPE_INT_RGB);
        java.awt.Graphics2D g = img.createGraphics();
        g.setColor(Color.WHITE);
        g.fillRect(0, 0, 200, 60);
        g.setColor(Color.BLACK);
        g.setFont(f);
        g.drawString("Hello", 8, 44);
        g.dispose();
        String off = ink(img);
        require(off == null, "\"Hello\" in Lucida Grande drew " + off + " off screen");
        Rectangle r = onEdt(() -> new Rectangle(hello.getLocationOnScreen(), hello.getSize()));
        String on = ink(robot.createScreenCapture(r));
        require(on == null, "the frame's \"Hello\" label at " + r + " shows " + on + hint(Color.BLACK));
        shot("hello.png", r, "\"Hello\" in Lucida Grande (the 10.9 system font: round, open letters, not Helvetica)");
    }

    // The plain-text types AppKit makes from one string; anything else (RTF, an image, files, an
    // app's own type) Java cannot see all of, so it could not be put back faithfully.
    static final java.util.Set<String> PLAIN = java.util.Set.of("«class utf8»", "«class ut16»", "«class utxt»", "string", "Unicode text");

    static java.util.List<String> clipboardTypes() throws Exception {
        String info = osascript("clipboard info");
        java.util.List<String> types = new java.util.ArrayList<>();
        String[] parts = info.isBlank() ? new String[0] : info.split(", ");
        for (int k = 0; k + 1 < parts.length; k += 2) types.add(parts[k]);
        java.util.Collections.sort(types);
        return types;
    }

    // A killed run (smoke-gui's time limit, the watchdog) cannot put the clipboard back and leaves the
    // test string on it; the step prints the clipboard's types (never its contents) first, so that is
    // visible.
    static void clipboard() throws Exception {
        java.awt.datatransfer.Clipboard cb = java.awt.Toolkit.getDefaultToolkit().getSystemClipboard();
        java.awt.datatransfer.DataFlavor sf = java.awt.datatransfer.DataFlavor.stringFlavor;
        java.util.List<String> types = clipboardTypes();
        System.out.println("note clipboard: it holds " + (types.isEmpty() ? "nothing" : "types " + types) + " before the step");
        for (String t : types) {
            if (!PLAIN.contains(t)) {
                throw new Skip("the clipboard holds " + t + ", which this step could not put back exactly, so it is left alone");
            }
        }
        String before = types.isEmpty() ? null : (String) cb.getData(sf);
        String mine = "GuiSmoke clipboard " + System.nanoTime();
        withCleanup(() -> {
            cb.setContents(new java.awt.datatransfer.StringSelection(mine), null);
            long until = System.nanoTime() + TimeUnit.SECONDS.toNanos(STEP_SECONDS);
            String back = cb.isDataFlavorAvailable(sf) ? (String) cb.getData(sf) : null;
            while (!mine.equals(back)) {
                require(System.nanoTime() < until, "the clipboard reads back " + back + ", not \"" + mine + "\"");
                Thread.sleep(100);
                back = cb.isDataFlavorAvailable(sf) ? (String) cb.getData(sf) : null;
            }
            String pasted = pbpaste();
            require(pasted.equals(mine), "/usr/bin/pbpaste reads \"" + pasted + "\", not \"" + mine + "\": Java's clipboard did not reach the AppKit pasteboard");
        }, () -> restoreClipboard(cb, before, types), "putting the clipboard back");
    }

    // pbcopy and pbpaste decode by the locale, so they get a UTF-8 one whatever the caller's is.
    static ProcessBuilder utf8(String... cmd) {
        ProcessBuilder pb = new ProcessBuilder(cmd);
        pb.environment().put("LC_ALL", "en_US.UTF-8");
        pb.environment().put("LANG", "en_US.UTF-8");
        return pb;
    }

    static String pbpaste() throws Exception {
        Process p = utf8("/usr/bin/pbpaste").redirectErrorStream(true).start();
        String out = new String(p.getInputStream().readAllBytes(), java.nio.charset.StandardCharsets.UTF_8);
        require(p.waitFor() == 0, "/usr/bin/pbpaste exited " + p.exitValue());
        return out;
    }

    // Java hands the pasteboard its contents on AppKit's thread, which a prompt exit can outrun (that
    // lost a clipboard once), so the step waits until the types and the text read back as they were.
    static void restoreClipboard(java.awt.datatransfer.Clipboard cb, String before, java.util.List<String> types) throws Exception {
        java.awt.datatransfer.Transferable put = before != null
            ? new java.awt.datatransfer.StringSelection(before)
            : new java.awt.datatransfer.Transferable() {
                public java.awt.datatransfer.DataFlavor[] getTransferDataFlavors() { return new java.awt.datatransfer.DataFlavor[0]; }
                public boolean isDataFlavorSupported(java.awt.datatransfer.DataFlavor f) { return false; }
                public Object getTransferData(java.awt.datatransfer.DataFlavor f) throws java.awt.datatransfer.UnsupportedFlavorException {
                    throw new java.awt.datatransfer.UnsupportedFlavorException(f);
                }
            };
        cb.setContents(put, null);
        long until = System.nanoTime() + TimeUnit.SECONDS.toNanos(STEP_SECONDS);
        while (true) {
            java.util.List<String> now = clipboardTypes();
            boolean same = before == null ? now.isEmpty() : now.equals(types) && pbpaste().equals(before);
            if (same) return;
            require(System.nanoTime() < until, "the clipboard did not go back as it was in " + STEP_SECONDS + " s: it holds " + now + ", not " + types);
            Thread.sleep(100);
        }
    }

    static Point centreOf(java.awt.Component c) throws Exception {
        return onEdt(() -> {
            Point p = c.getLocationOnScreen();
            return new Point(p.x + c.getWidth() / 2, p.y + c.getHeight() / 2);
        });
    }

    static final java.util.List<String> dndTrace = java.util.Collections.synchronizedList(new java.util.ArrayList<>());
    static volatile long dndStart;

    static void trace(String what) {
        dndTrace.add(String.format("%6d ms %s", (System.nanoTime() - dndStart) / 1_000_000, what));
    }

    static String nameOf(Object c) {
        return c == dragSource ? "source" : c == dragTarget ? "target" : c == null ? "null" : c.getClass().getSimpleName();
    }

    // What each layer saw, printed with a failure (or always, with -Dguismoke.trace=true): AWT's mouse
    // events per field, the DragSource callbacks that come only once AppKit's drag session runs, and
    // the target's DropTarget callbacks.
    static void listenToDrag() throws Exception {
        final int[] dragged = {0};
        final int[] moved = {0};
        final int[] over = {0};
        final int[] targetOver = {0};
        java.awt.Toolkit.getDefaultToolkit().addAWTEventListener(e -> {
            java.awt.event.MouseEvent m = (java.awt.event.MouseEvent) e;
            switch (m.getID()) {
                case java.awt.event.MouseEvent.MOUSE_PRESSED -> trace("awt pressed on " + nameOf(m.getComponent()) + " at " + m.getLocationOnScreen());
                case java.awt.event.MouseEvent.MOUSE_RELEASED -> trace("awt released on " + nameOf(m.getComponent()) + " at " + m.getLocationOnScreen() + " after " + dragged[0] + " drag events");
                case java.awt.event.MouseEvent.MOUSE_DRAGGED -> { if (dragged[0]++ == 0) trace("awt first drag event on " + nameOf(m.getComponent()) + " at " + m.getLocationOnScreen()); }
                default -> { }
            }
        }, java.awt.AWTEvent.MOUSE_EVENT_MASK | java.awt.AWTEvent.MOUSE_MOTION_EVENT_MASK);
        java.awt.dnd.DragSource ds = java.awt.dnd.DragSource.getDefaultDragSource();
        ds.addDragSourceMotionListener(e -> { if (moved[0]++ == 0) trace("drag source: first move, the native drag session is running, at " + e.getLocation()); });
        ds.addDragSourceListener(new java.awt.dnd.DragSourceListener() {
            public void dragEnter(java.awt.dnd.DragSourceDragEvent e) { trace("drag source: enter, action " + e.getDropAction()); }
            public void dragOver(java.awt.dnd.DragSourceDragEvent e) { if (over[0]++ == 0) trace("drag source: first over, action " + e.getDropAction()); }
            public void dropActionChanged(java.awt.dnd.DragSourceDragEvent e) { trace("drag source: action changed to " + e.getDropAction()); }
            public void dragExit(java.awt.dnd.DragSourceEvent e) { trace("drag source: exit"); }
            public void dragDropEnd(java.awt.dnd.DragSourceDropEvent e) { trace("drag source: drop end, success " + e.getDropSuccess() + ", action " + e.getDropAction() + " after " + moved[0] + " moves"); }
        });
        onEdt(() -> {
            dragTarget.getDropTarget().addDropTargetListener(new java.awt.dnd.DropTargetAdapter() {
                @Override public void dragEnter(java.awt.dnd.DropTargetDragEvent e) { trace("drop target: enter, action " + e.getDropAction() + ", flavours " + java.util.Arrays.toString(e.getCurrentDataFlavors())); }
                @Override public void dragOver(java.awt.dnd.DropTargetDragEvent e) { if (targetOver[0]++ == 0) trace("drop target: first over"); }
                @Override public void dragExit(java.awt.dnd.DropTargetEvent e) { trace("drop target: exit"); }
                @Override public void drop(java.awt.dnd.DropTargetDropEvent e) { trace("drop target: drop, action " + e.getDropAction()); }
            });
            return null;
        });
    }

    // Swing starts a text drag only from a press on the selection (BasicTextUI.DragListener's
    // isDragPossible: the press's model position must be at least the selection's start and below
    // its end); the field's centre lies past the end of left-aligned "dragme", which made the press
    // a caret click on the 10.9 box. So the press goes between the second and fifth characters.
    static Point onSelectedText() throws Exception {
        return onEdt(() -> {
            java.awt.geom.Rectangle2D a = dragSource.modelToView2D(1);
            java.awt.geom.Rectangle2D b = dragSource.modelToView2D(5);
            Point p = dragSource.getLocationOnScreen();
            return new Point(p.x + (int) Math.round((a.getX() + b.getX()) / 2), p.y + (int) Math.round(a.getCenterY()));
        });
    }

    static void dnd() throws Exception {
        dndStart = System.nanoTime();
        Thread.UncaughtExceptionHandler earlier = Thread.getDefaultUncaughtExceptionHandler();
        Thread.setDefaultUncaughtExceptionHandler((t, e) -> trace("uncaught on " + t.getName() + ": " + e));
        listenToDrag();
        onEdt(() -> { dragSource.requestFocusInWindow(); dragSource.selectAll(); return null; });
        settle();
        Point from = onSelectedText();
        Point to = centreOf(dragTarget);
        String where = onEdt(() -> {
            Point p = dragSource.getLocationOnScreen();
            int pos = dragSource.viewToModel2D(new Point(from.x - p.x, from.y - p.y));
            return "source selection " + dragSource.getSelectionStart() + "-" + dragSource.getSelectionEnd()
                + " of \"" + dragSource.getText() + "\", press at model position " + pos;
        });
        trace(where);
        trace("robot: press at " + from + ", drag to " + to);
        robot.mouseMove(from.x, from.y);
        robot.mousePress(java.awt.event.InputEvent.BUTTON1_DOWN_MASK);
        robot.delay(200);
        // Swing starts a drag only after the mouse moves past its threshold while pressed, and
        // AppKit's drag session follows the pointer only once it has begun, so the moves are small
        // and keep coming over the target before the release.
        for (int i = 1; i <= 30; i++) {
            robot.mouseMove(from.x + (to.x - from.x) * i / 30, from.y + (to.y - from.y) * i / 30);
            robot.delay(30);
        }
        for (int i = 0; i < 6; i++) {
            robot.mouseMove(to.x + (i % 2 == 0 ? 2 : -2), to.y);
            robot.delay(60);
        }
        robot.mouseMove(to.x, to.y);
        robot.delay(300);
        trace("robot: release at " + to);
        robot.mouseRelease(java.awt.event.InputEvent.BUTTON1_DOWN_MASK);
        long until = System.nanoTime() + TimeUnit.SECONDS.toNanos(STEP_SECONDS);
        String text = onEdt(() -> dragTarget.getText());
        while (!text.contains("dragme")) {
            if (System.nanoTime() >= until) {
                printTrace();
                require(false, "after the drag the target field holds \"" + text + "\", not \"dragme\" (the trace above says which layer stopped)");
            }
            Thread.sleep(100);
            text = onEdt(() -> dragTarget.getText());
        }
        if (Boolean.getBoolean("guismoke.trace")) printTrace();
        Thread.setDefaultUncaughtExceptionHandler(earlier);
    }

    static void printTrace() {
        synchronized (dndTrace) {
            for (String t : dndTrace) System.out.println("trace dnd: " + t);
        }
    }

    static void badge() throws Exception {
        require(java.awt.Taskbar.isTaskbarSupported(), "Taskbar is not supported");
        java.awt.Taskbar tb = java.awt.Taskbar.getTaskbar();
        require(tb.isSupported(java.awt.Taskbar.Feature.ICON_BADGE_TEXT), "Taskbar does not support ICON_BADGE_TEXT");
        String see = dockAutohides()
            ? "nothing to judge by eye: this Dock autohides (com.apple.dock autohide = 1); setIconBadge(\"17\") was supported and threw nothing"
            : "the Dock's GuiSmoke (java) icon wears a red badge reading 17";
        System.out.println("note badge: " + see);
        withCleanup(() -> {
            tb.setIconBadge("17");
            robot.delay(1000);
            Rectangle screen = GraphicsEnvironment.getLocalGraphicsEnvironment().getDefaultScreenDevice()
                .getDefaultConfiguration().getBounds();
            shot("dock.png", screen, see);
        }, () -> tb.setIconBadge(null), "clearing the badge");
    }

    // Read, never changed: the maintainer's Dock setting decides whether dock.png can show anything.
    static boolean dockAutohides() {
        try {
            Process p = new ProcessBuilder("/usr/bin/defaults", "read", "com.apple.dock", "autohide").redirectErrorStream(true).start();
            String out = new String(p.getInputStream().readAllBytes(), java.nio.charset.StandardCharsets.UTF_8).trim();
            return p.waitFor() == 0 && (out.equals("1") || out.equalsIgnoreCase("true"));
        } catch (Exception e) {
            return false;
        }
    }

    static String osascript(String... lines) throws Exception {
        java.util.List<String> cmd = new java.util.ArrayList<>();
        cmd.add("/usr/bin/osascript");
        for (String l : lines) { cmd.add("-e"); cmd.add(l); }
        Process p = utf8(cmd.toArray(new String[0])).redirectErrorStream(true).start();
        String out = new String(p.getInputStream().readAllBytes(), java.nio.charset.StandardCharsets.UTF_8).trim();
        require(p.waitFor() == 0, "/usr/bin/osascript exited " + p.exitValue() + ": " + out);
        return out;
    }

    // Each Finder window by the POSIX path of the folder it shows, so the step knows which folder
    // opened. 10.9's Finder refuses "close (every Finder window whose ...)" (-10010), so windows are
    // walked one by one; a window whose target is no folder is skipped.
    static java.util.List<String> finderWindows() throws Exception {
        String out = osascript(
            "tell application \"Finder\"",
            "  set out to \"\"",
            "  repeat with w in (get every Finder window)",
            "    try",
            "      set out to out & (POSIX path of (target of w as alias)) & linefeed",
            "    end try",
            "  end repeat",
            "  return out",
            "end tell");
        java.util.List<String> paths = new java.util.ArrayList<>();
        for (String l : out.split("\n")) if (!l.isBlank()) paths.add(l.trim());
        return paths;
    }

    static void closeFinderWindow(String path) throws Exception {
        osascript(
            "tell application \"Finder\"",
            "  repeat with w in (get every Finder window)",
            "    try",
            "      if POSIX path of (target of w as alias) is \"" + path.replace("\\", "\\\\").replace("\"", "\\\"") + "\" then close w",
            "    end try",
            "  end repeat",
            "end tell");
    }

    static String folderPath(java.nio.file.Path p) throws Exception {
        return p.toRealPath().toString() + "/";
    }

    // A loaded 10.9 box's Finder took over 20 s to show Desktop.open's window (Task 19), so it gets a
    // minute; a window that comes in the grace after that is named in the failure, and closed.
    static final long FINDER_SECONDS = 60;
    static final long FINDER_GRACE_SECONDS = 15;

    static boolean awaitFinderWindow(String path, long seconds) throws Exception {
        long until = System.nanoTime() + TimeUnit.SECONDS.toNanos(seconds);
        while (true) {
            if (finderWindows().contains(path)) return true;
            if (System.nanoTime() >= until) return false;
            Thread.sleep(250);
        }
    }

    static void finderOpened(String path, String parent, java.util.List<String> before, String how) throws Exception {
        long start = System.nanoTime();
        long until = start + TimeUnit.SECONDS.toNanos(FINDER_SECONDS);
        java.util.List<String> now = finderWindows();
        while (!now.contains(path)) {
            require(!(now.contains(parent) && !before.contains(parent)),
                how + " opened a Finder window on the parent " + parent + ", not on " + path);
            if (System.nanoTime() >= until) {
                java.util.List<String> shown = now;
                if (awaitFinderWindow(path, FINDER_GRACE_SECONDS)) {
                    long late = (System.nanoTime() - start) / 1_000_000_000L;
                    closeFinderWindow(path);
                    throw new Failure(how + " opened its Finder window on " + path + " only after about " + late
                        + " s, past the " + FINDER_SECONDS + " s allowed (a loaded Finder); the window was closed");
                }
                throw new Failure(how + " opened no Finder window on " + path + " in " + (FINDER_SECONDS + FINDER_GRACE_SECONDS)
                    + " s; Finder shows " + shown);
            }
            Thread.sleep(250);
            now = finderWindows();
        }
        closeFinderWindow(path);
    }

    static void desktop() throws Exception {
        require(java.awt.Desktop.isDesktopSupported(), "Desktop is not supported");
        java.awt.Desktop d = java.awt.Desktop.getDesktop();
        require(d.isSupported(java.awt.Desktop.Action.OPEN) && d.isSupported(java.awt.Desktop.Action.BROWSE),
            "Desktop does not support OPEN and BROWSE");
        // open and browse are reported apart: a failing open does not keep browse from running.
        Throwable openFailed = null;
        try { desktopOpen(d); } catch (Throwable t) { openFailed = t; }
        Throwable browseFailed = null;
        try { desktopBrowse(d); } catch (Throwable t) { browseFailed = t; }
        if (openFailed != null && browseFailed != null) {
            throw new Failure("open: " + why(openFailed) + "; browse: " + why(browseFailed));
        }
        if (openFailed != null) throw new Failure("open: " + why(openFailed) + (Boolean.getBoolean("guismoke.browse") ? "; browse ran (see its look line)" : ""));
        if (browseFailed != null) throw new Failure("browse: " + why(browseFailed));
    }

    static void desktopOpen(java.awt.Desktop d) throws Exception {
        java.nio.file.Path opened = java.nio.file.Files.createTempDirectory("guismoke-open-");
        String openedPath = folderPath(opened);
        String parent = folderPath(opened.getParent());
        java.util.concurrent.atomic.AtomicReference<java.util.List<String>> before = new java.util.concurrent.atomic.AtomicReference<>();
        java.util.concurrent.atomic.AtomicBoolean seen = new java.util.concurrent.atomic.AtomicBoolean();
        // Close whatever this step opened before its folder goes, even after a failure, so a run
        // leaves no window behind (a deleted folder's window falls back to its parent); the close and
        // the delete are guarded apart, so one failing does not skip the other.
        withCleanup(() -> {
            before.set(finderWindows());
            d.open(opened.toFile());
            finderOpened(openedPath, parent, before.get(), "Desktop.open(" + opened + ")");
            seen.set(true);
        }, () -> withCleanup(() -> {
            java.util.List<String> was = before.get();
            // a window Finder shows only now, after a failure, is closed before its folder goes
            if (!seen.get() && !finderWindows().contains(openedPath)) awaitFinderWindow(openedPath, 5);
            for (String w : finderWindows()) {
                if (w.equals(openedPath) || (was != null && !was.contains(w) && w.equals(parent))) {
                    closeFinderWindow(w);
                }
            }
        }, () -> java.nio.file.Files.deleteIfExists(opened), "deleting " + opened), "closing its Finder window");
    }

    static void desktopBrowse(java.awt.Desktop d) throws Exception {
        // A smoke run must not open pages in the maintainer's own browser (the controller's ruling,
        // 2026-11-07): browse is called only when asked for, and judged by eye.
        if (Boolean.getBoolean("guismoke.browse")) {
            String mark = "GuiSmoke browse " + System.nanoTime();
            java.nio.file.Path page = java.nio.file.Files.createTempFile("guismoke-browse-", ".html");
            java.nio.file.Files.writeString(page, "<!doctype html><title>" + mark + "</title><h1>" + mark + "</h1>\n");
            d.browse(page.toUri());
            System.out.println("look desktop: your default browser should show a page reading \"" + mark
                + "\" (" + page.toUri() + "); close that tab, then delete " + page);
        } else {
            System.out.println("note desktop: Desktop.browse not called, so no page opens in your browser;"
                + " BROWSE is supported, and Java cannot name the default browser (SMOKE_GUI_BROWSE=1 browses a page)");
        }
    }

    static void print() throws Exception {
        javax.print.StreamPrintServiceFactory[] fs = javax.print.StreamPrintServiceFactory.lookupStreamPrintServiceFactories(
            javax.print.DocFlavor.SERVICE_FORMATTED.PRINTABLE, "application/postscript");
        require(fs.length > 0, "no PostScript StreamPrintServiceFactory");
        java.io.File out = java.io.File.createTempFile("guismoke-print-", ".ps");
        final boolean[] drew = {false};
        try {
            try (java.io.FileOutputStream os = new java.io.FileOutputStream(out)) {
                javax.print.StreamPrintService svc = fs[0].getPrintService(os);
                java.awt.print.PrinterJob job = java.awt.print.PrinterJob.getPrinterJob();
                // A StreamPrintService makes CPrinterJob spool to the stream before it touches the
                // native print path, so neither a printer queue nor a dialog is reachable.
                job.setPrintService(svc);
                require(job.getPrintService() == svc,
                    "the PrinterJob's service is " + job.getPrintService() + ", not the stream: refusing to print");
                job.setPrintable((g, pf, page) -> {
                    if (page > 0) return java.awt.print.Printable.NO_SUCH_PAGE;
                    drew[0] = true;
                    g.setFont(new java.awt.Font("Lucida Grande", java.awt.Font.PLAIN, 24));
                    g.drawString("GuiSmoke", (int) pf.getImageableX() + 36, (int) pf.getImageableY() + 72);
                    return java.awt.print.Printable.PAGE_EXISTS;
                });
                job.print();
            }
            byte[] head = java.util.Arrays.copyOf(java.nio.file.Files.readAllBytes(out.toPath()), 10);
            String h = new String(head, java.nio.charset.StandardCharsets.ISO_8859_1);
            require(drew[0], "the job never asked the Printable to draw page 0");
            require(h.startsWith("%!PS-Adobe"), "the printed file starts \"" + h + "\", not %!PS-Adobe");
            require(out.length() > 1000, "the printed file is " + out.length() + " bytes, not over 1000");
        } finally {
            out.delete();
        }
    }

    static void close() throws Exception {
        SwingUtilities.invokeLater(() ->
            frame.dispatchEvent(new WindowEvent(frame, WindowEvent.WINDOW_CLOSING)));
        require(closed.await(STEP_SECONDS, TimeUnit.SECONDS), "windowClosed did not arrive in " + STEP_SECONDS + " s");
        require(!onEdt(() -> frame.isDisplayable()), "the frame is still displayable after closing");
    }
}
