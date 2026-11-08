/*
 * GuiSmoke: the headful smoke tests/smoke-gui.sh runs on Mac OS X 10.9 under a console login.
 * Each step prints "ok <step>" or "FAIL <step>: <why>"; the first failure ends the run with exit 1,
 * and a watchdog ends a hung run with exit 2. Steps, in order:
 *   headful    GraphicsEnvironment is not headless and Java2D's pipeline is OpenGL (patches/0015);
 *   frame      a JFrame with a JMenuBar, a JTextField and a custom-painted JPanel is showing;
 *   menubar    the menu bar is showing, with its one menu;
 *   paint      the panel's paintComponent ran;
 *   pixel      Robot.getPixelColor at the panel's centre reads the panel's colour;
 *   resize     the frame grows, the panel follows, and the pixel at its new centre still reads true;
 *   fullscreen the frame becomes the screen's full-screen window, fills the screen, and comes back;
 *   type       Robot types "mvk" into the focused text field;
 *   close      a WINDOW_CLOSING event disposes the frame, and windowClosed arrives.
 */
import java.awt.Color;
import java.awt.Dimension;
import java.awt.EventQueue;
import java.awt.Graphics;
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
    // An uncommon colour, so the read-back cannot match a default background by chance.
    static final Color FILL = new Color(0x21, 0x9e, 0x5b);
    static final int TOLERANCE = 12;
    static final long STEP_SECONDS = 20;

    static JFrame frame;
    static JPanel panel;
    static JTextField field;
    static JMenuBar bar;
    static final CountDownLatch painted = new CountDownLatch(1);
    static final CountDownLatch closed = new CountDownLatch(1);
    static Robot robot;

    static final class Failure extends RuntimeException {
        Failure(String why) { super(why); }
    }

    interface Step { void run() throws Exception; }

    public static void main(String[] args) throws Exception {
        Thread watchdog = new Thread(() -> {
            try { Thread.sleep(TimeUnit.SECONDS.toMillis(180)); } catch (InterruptedException e) { return; }
            System.out.println("FAIL watchdog: GuiSmoke did not finish in 180 s");
            System.out.flush();
            Runtime.getRuntime().halt(2);
        });
        watchdog.setDaemon(true);
        watchdog.start();

        step("headful", GuiSmoke::headful);
        step("frame", GuiSmoke::frame);
        step("menubar", GuiSmoke::menubar);
        step("paint", GuiSmoke::paint);
        step("pixel", GuiSmoke::pixel);
        step("resize", GuiSmoke::resize);
        step("fullscreen", GuiSmoke::fullscreen);
        step("type", GuiSmoke::type);
        step("close", GuiSmoke::close);
        System.out.println("PASS GuiSmoke");
        System.out.flush();
        System.exit(0);
    }

    static void step(String name, Step s) {
        try {
            s.run();
            System.out.println("ok " + name);
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
            field = new JTextField(20);
            panel = new JPanel() {
                @Override protected void paintComponent(Graphics g) {
                    super.paintComponent(g);
                    g.setColor(FILL);
                    g.fillRect(0, 0, getWidth(), getHeight());
                    painted.countDown();
                }
            };
            panel.setPreferredSize(new Dimension(320, 200));
            panel.setBorder(BorderFactory.createEmptyBorder());
            frame.getContentPane().add(field, java.awt.BorderLayout.NORTH);
            frame.getContentPane().add(panel, java.awt.BorderLayout.CENTER);
            frame.pack();
            frame.setLocation(80, 80);
            frame.setVisible(true);
            return null;
        });
        long until = System.nanoTime() + TimeUnit.SECONDS.toNanos(STEP_SECONDS);
        while (!onEdt(() -> frame.isShowing() && panel.isShowing())) {
            require(System.nanoTime() < until, "the frame is not showing after " + STEP_SECONDS + " s");
            Thread.sleep(100);
        }
        settle();
    }

    static void menubar() throws Exception {
        require(onEdt(() -> bar.isShowing()), "the JMenuBar is not showing");
        require(onEdt(() -> bar.getMenuCount()) == 1, "the JMenuBar has " + onEdt(() -> bar.getMenuCount()) + " menus, not 1");
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

    static void readBack(String where) throws Exception {
        Point c = panelCentre();
        long until = System.nanoTime() + TimeUnit.SECONDS.toNanos(STEP_SECONDS);
        Color got = robot.getPixelColor(c.x, c.y);
        while (!near(got, FILL)) {
            require(System.nanoTime() < until, "Robot.getPixelColor(" + c.x + ", " + c.y + ") " + where
                + " is " + got + ", not " + FILL + " (within " + TOLERANCE + ")");
            robot.delay(200);
            got = robot.getPixelColor(c.x, c.y);
        }
    }

    static void pixel() throws Exception {
        readBack("at the panel's centre");
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
        // A process started from a shell (ssh, a script) is not the active application, and macOS
        // gives a window focus only in the active one; Desktop asks AppKit to activate this one.
        if (java.awt.Desktop.isDesktopSupported()
                && java.awt.Desktop.getDesktop().isSupported(java.awt.Desktop.Action.APP_REQUEST_FOREGROUND)) {
            java.awt.Desktop.getDesktop().requestForeground(true);
        }
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

    static void close() throws Exception {
        SwingUtilities.invokeLater(() ->
            frame.dispatchEvent(new WindowEvent(frame, WindowEvent.WINDOW_CLOSING)));
        require(closed.await(STEP_SECONDS, TimeUnit.SECONDS), "windowClosed did not arrive in " + STEP_SECONDS + " s");
        require(!onEdt(() -> frame.isDisplayable()), "the frame is still displayable after closing");
    }
}
