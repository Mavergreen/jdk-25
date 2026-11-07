import java.awt.Color;
import java.awt.Font;
import java.awt.Graphics2D;
import java.awt.GraphicsEnvironment;
import java.awt.HeadlessException;
import java.awt.Toolkit;
import java.awt.image.BufferedImage;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.lang.management.ManagementFactory;
import java.lang.management.ThreadMXBean;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.ByteBuffer;
import java.nio.channels.DatagramChannel;
import java.nio.channels.SelectionKey;
import java.nio.channels.Selector;
import java.nio.channels.ServerSocketChannel;
import java.nio.channels.SocketChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.attribute.FileTime;
import java.nio.file.attribute.PosixFilePermission;
import java.nio.file.attribute.PosixFilePermissions;
import java.security.KeyStore;
import java.security.cert.Certificate;
import java.security.cert.CertificateFactory;
import java.time.Duration;
import java.util.Arrays;
import java.util.Set;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.locks.LockSupport;
import java.util.zip.GZIPInputStream;
import java.util.zip.GZIPOutputStream;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import java.util.zip.ZipOutputStream;
import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLServerSocket;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.TrustManagerFactory;

public class LegacySmoke {
    interface Check {
        void run() throws Exception;
    }

    static int failures;

    public static void main(String[] args) {
        boolean network = Arrays.asList(args).contains("--network");
        run("clocks", LegacySmoke::clocks);
        run("fileCopy", LegacySmoke::fileCopy);
        run("zip", LegacySmoke::zip);
        run("udp", LegacySmoke::udp);
        run("tcp", LegacySmoke::tcp);
        run("urgentData", LegacySmoke::urgentData);
        run("tls", LegacySmoke::tls);
        run("process", LegacySmoke::process);
        run("headless", LegacySmoke::headless);
        run("fonts", LegacySmoke::fonts);
        if (network) {
            run("https", LegacySmoke::https);
        }
        System.exit(failures == 0 ? 0 : 1);
    }

    static void run(String name, Check check) {
        try {
            check.run();
            System.out.println("ok " + name);
        } catch (Throwable t) {
            failures++;
            String why = String.valueOf(t).replace('\n', ' ').replace('\r', ' ');
            System.out.println("FAIL " + name + ": " + why);
        }
        System.out.flush();
    }

    static void require(boolean condition, String why) {
        if (!condition) {
            throw new AssertionError(why);
        }
    }

    static void clocks() throws Exception {
        long previous = System.nanoTime();
        for (int i = 0; i < 10_000; i++) {
            long now = System.nanoTime();
            require(now - previous >= 0, "nanoTime went backwards at read " + i + " by " + (previous - now) + " ns");
            previous = now;
        }

        long start = System.nanoTime();
        Thread.sleep(50);
        long sleptNanos = System.nanoTime() - start;
        require(sleptNanos >= 50_000_000L, "Thread.sleep(50) took " + sleptNanos / 1_000_000 + " ms");
        require(sleptNanos < 500_000_000L, "Thread.sleep(50) took " + sleptNanos / 1_000_000 + " ms");

        start = System.nanoTime();
        long parkDeadline = start + 20_000_000L;
        int parkCalls = 0;
        while (true) {
            long remaining = parkDeadline - System.nanoTime();
            if (remaining <= 0) {
                break;
            }
            LockSupport.parkNanos(remaining);
            parkCalls++;
            require(parkCalls <= 1000, "parkNanos returned early on each of " + parkCalls
                + " calls before the 20 ms deadline; a correct implementation needs 1 or a handful");
        }
        long parkedNanos = System.nanoTime() - start;
        require(parkedNanos >= 20_000_000L, "parkNanos loop ended after " + parkedNanos + " ns");

        long[] virtualNanos = new long[1];
        Throwable[] virtualFailure = new Throwable[1];
        Thread virtual = Thread.ofVirtual().start(() -> {
            try {
                long begin = System.nanoTime();
                Thread.sleep(30);
                virtualNanos[0] = System.nanoTime() - begin;
            } catch (Throwable t) {
                virtualFailure[0] = t;
            }
        });
        virtual.join(10_000);
        require(!virtual.isAlive(), "virtual thread sleep(30) did not finish in 10 s");
        require(virtualFailure[0] == null, "virtual thread failed: " + virtualFailure[0]);
        require(virtualNanos[0] >= 30_000_000L, "virtual thread sleep(30) took " + virtualNanos[0] + " ns");
    }

    static void deleteTree(Path root) {
        try {
            if (Files.isDirectory(root)) {
                try (var entries = Files.list(root)) {
                    for (Path entry : (Iterable<Path>) entries::iterator) {
                        deleteTree(entry);
                    }
                }
            }
            Files.deleteIfExists(root);
        } catch (Exception ignored) {
        }
    }

    static void fileCopy() throws Exception {
        Path dir = Files.createTempDirectory("legacysmoke-copy");
        try {
            Path a = dir.resolve("a");
            Path b = dir.resolve("b");
            Files.write(a, "payload".getBytes(StandardCharsets.UTF_8));

            Files.setLastModifiedTime(a, FileTime.fromMillis(1_500_000_000_123L));
            long aSeconds = Files.getLastModifiedTime(a).toInstant().getEpochSecond();
            require(aSeconds == 1_500_000_000L, "setLastModifiedTime round-trip gave " + aSeconds + ", wanted 1500000000");

            Set<PosixFilePermission> perms = PosixFilePermissions.fromString("rw-r-----");
            Files.setPosixFilePermissions(a, perms);
            require(Files.getPosixFilePermissions(a).equals(perms),
                "getPosixFilePermissions gave " + PosixFilePermissions.toString(Files.getPosixFilePermissions(a)));

            Files.copy(a, b, StandardCopyOption.COPY_ATTRIBUTES);
            long bSeconds = Files.getLastModifiedTime(b).toInstant().getEpochSecond();
            require(bSeconds == aSeconds, "copy mtime " + bSeconds + " differs from source " + aSeconds);
            require(Files.getPosixFilePermissions(b).equals(perms), "copy permissions differ from source");
            require(Arrays.equals(Files.readAllBytes(b), Files.readAllBytes(a)), "copy contents differ");
        } finally {
            deleteTree(dir);
        }
    }

    static byte[] patterned(int length) {
        byte[] data = new byte[length];
        for (int i = 0; i < length; i++) {
            data[i] = (byte) ((i * 31) ^ (i >>> 7));
        }
        return data;
    }

    static byte[] readAll(InputStream in) throws Exception {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        in.transferTo(out);
        return out.toByteArray();
    }

    static void zip() throws Exception {
        byte[] first = patterned(200_000);
        byte[] second = "stored entry".getBytes(StandardCharsets.UTF_8);
        Path dir = Files.createTempDirectory("legacysmoke-zip");
        try {
            Path zipPath = dir.resolve("t.zip");
            try (ZipOutputStream out = new ZipOutputStream(Files.newOutputStream(zipPath))) {
                out.putNextEntry(new ZipEntry("deflated.bin"));
                out.write(first);
                out.closeEntry();
                ZipEntry stored = new ZipEntry("stored.txt");
                stored.setMethod(ZipEntry.STORED);
                stored.setSize(second.length);
                stored.setCompressedSize(second.length);
                java.util.zip.CRC32 crc = new java.util.zip.CRC32();
                crc.update(second);
                stored.setCrc(crc.getValue());
                out.putNextEntry(stored);
                out.write(second);
                out.closeEntry();
            }
            try (ZipFile zf = new ZipFile(zipPath.toFile())) {
                require(zf.size() == 2, "zip has " + zf.size() + " entries, wanted 2");
                try (InputStream in = zf.getInputStream(zf.getEntry("deflated.bin"))) {
                    require(Arrays.equals(readAll(in), first), "deflated entry differs");
                }
                try (InputStream in = zf.getInputStream(zf.getEntry("stored.txt"))) {
                    require(Arrays.equals(readAll(in), second), "stored entry differs");
                }
            }

            ByteArrayOutputStream gz = new ByteArrayOutputStream();
            try (GZIPOutputStream out = new GZIPOutputStream(gz)) {
                out.write(first);
            }
            try (GZIPInputStream in = new GZIPInputStream(new java.io.ByteArrayInputStream(gz.toByteArray()))) {
                require(Arrays.equals(readAll(in), first), "gzip round-trip differs");
            }
        } finally {
            deleteTree(dir);
        }
    }

    static byte[] receive(DatagramSocket server, String what) throws Exception {
        byte[] buffer = new byte[64];
        DatagramPacket packet = new DatagramPacket(buffer, buffer.length);
        try {
            server.receive(packet);
        } catch (java.net.SocketTimeoutException e) {
            throw new AssertionError(what + ": datagram never arrived");
        }
        return Arrays.copyOf(packet.getData(), packet.getLength());
    }

    static void udpRound(InetAddress loopback) throws Exception {
        String family = loopback.getHostAddress();
        try (DatagramSocket serverA = new DatagramSocket(0, loopback);
             DatagramSocket serverB = new DatagramSocket(0, loopback);
             DatagramSocket client = new DatagramSocket(0, loopback)) {
            serverA.setSoTimeout(5000);
            serverB.setSoTimeout(5000);
            byte[] one = "one".getBytes(StandardCharsets.UTF_8);
            byte[] two = "two".getBytes(StandardCharsets.UTF_8);
            byte[] three = "three".getBytes(StandardCharsets.UTF_8);

            client.connect(loopback, serverA.getLocalPort());
            require(client.isConnected(), family + ": socket not connected after connect");
            client.send(new DatagramPacket(one, one.length));
            require(Arrays.equals(receive(serverA, family + " connected send"), one), family + ": payload differs");

            client.disconnect();
            require(!client.isConnected(), family + ": socket still connected after disconnect");
            require(client.getInetAddress() == null, family + ": remote address kept after disconnect");

            client.connect(loopback, serverB.getLocalPort());
            client.send(new DatagramPacket(two, two.length));
            require(Arrays.equals(receive(serverB, family + " reconnected send"), two), family + ": payload after reconnect differs");

            client.send(new DatagramPacket(three, three.length, loopback, serverB.getLocalPort()));
            require(Arrays.equals(receive(serverB, family + " send to connected peer"), three), family + ": addressed send differs");
        }

        try (DatagramSocket serverA = new DatagramSocket(0, loopback);
             DatagramChannel channel = DatagramChannel.open()) {
            serverA.setSoTimeout(5000);
            channel.bind(new InetSocketAddress(loopback, 0));
            channel.connect(new InetSocketAddress(loopback, serverA.getLocalPort()));
            require(channel.isConnected(), family + ": channel not connected");
            channel.write(ByteBuffer.wrap("chan".getBytes(StandardCharsets.UTF_8)));
            require(Arrays.equals(receive(serverA, family + " channel write"), "chan".getBytes(StandardCharsets.UTF_8)),
                family + ": channel payload differs");
            channel.disconnect();
            require(!channel.isConnected(), family + ": channel still connected after disconnect");
            channel.connect(new InetSocketAddress(loopback, serverA.getLocalPort()));
            channel.write(ByteBuffer.wrap("again".getBytes(StandardCharsets.UTF_8)));
            require(Arrays.equals(receive(serverA, family + " channel reconnect"), "again".getBytes(StandardCharsets.UTF_8)),
                family + ": channel payload after reconnect differs");
        }
    }

    static void udp() throws Exception {
        udpRound(InetAddress.getByAddress(new byte[] {127, 0, 0, 1}));
        udpRound(InetAddress.getByAddress(ipv6Loopback()));
    }

    static byte[] ipv6Loopback() {
        byte[] address = new byte[16];
        address[15] = 1;
        return address;
    }

    static void tcp() throws Exception {
        InetAddress loopback = InetAddress.getByAddress(new byte[] {127, 0, 0, 1});
        Throwable[] serverFailure = new Throwable[1];
        try (ServerSocket server = new ServerSocket(0, 5, loopback)) {
            Thread echo = new Thread(() -> {
                try (Socket peer = server.accept()) {
                    peer.setSoTimeout(5000);
                    InputStream in = peer.getInputStream();
                    OutputStream out = peer.getOutputStream();
                    int c;
                    while ((c = in.read()) != -1) {
                        out.write(c);
                    }
                    out.flush();
                } catch (Throwable t) {
                    serverFailure[0] = t;
                }
            });
            echo.start();
            try (Socket client = new Socket(loopback, server.getLocalPort())) {
                client.setSoTimeout(5000);
                byte[] message = patterned(70_000);
                OutputStream out = client.getOutputStream();
                Thread writer = new Thread(() -> {
                    try {
                        out.write(message);
                        out.flush();
                        client.shutdownOutput();
                    } catch (Throwable t) {
                        serverFailure[0] = t;
                    }
                });
                writer.start();
                byte[] echoed = readAll(client.getInputStream());
                writer.join(10_000);
                require(Arrays.equals(echoed, message), "echoed " + echoed.length + " bytes, differing from the " + message.length + " sent");
            }
            echo.join(10_000);
            require(!echo.isAlive(), "echo server did not finish");
        }
        require(serverFailure[0] == null, "echo thread failed: " + serverFailure[0]);
    }

    static void urgentData() throws Exception {
        InetAddress loopback = InetAddress.getByAddress(new byte[] {127, 0, 0, 1});
        try (ServerSocketChannel server = ServerSocketChannel.open().bind(new InetSocketAddress(loopback, 0));
             Socket client = new Socket(loopback, server.socket().getLocalPort());
             SocketChannel peer = server.accept();
             Selector selector = Selector.open()) {
            peer.configureBlocking(false);
            peer.register(selector, SelectionKey.OP_READ);
            client.sendUrgentData(0xff);
            quietSelect(selector, "with only urgent data pending");
            client.getOutputStream().write(new byte[] {1, 2, 3});
            require(selector.select(5000) == 1, "select did not report the 3 bytes sent after the urgent byte");
            ByteBuffer got = ByteBuffer.allocate(8);
            peer.read(got);
            require(got.position() == 3 && got.get(0) == 1, "read " + got.position() + " bytes after the urgent byte, not the 3 sent");
            selector.selectedKeys().clear();
            client.sendUrgentData(0xfe);
            quietSelect(selector, "with urgent data pending after normal traffic");
            client.getOutputStream().write(new byte[] {4, 5});
            require(selector.select(5000) == 1, "select did not report the 2 bytes sent after the second urgent byte");
            got.clear();
            peer.read(got);
            require(got.position() == 2 && got.get(0) == 4, "read " + got.position() + " bytes after the second urgent byte, not the 2 sent");
            selector.selectedKeys().clear();
            peer.socket().setOOBInline(true);
            client.sendUrgentData(0x7f);
            require(selector.select(5000) == 1, "with SO_OOBINLINE on, select did not report the urgent byte");
            got.clear();
            peer.read(got);
            require(got.position() == 1 && got.get(0) == 0x7f, "with SO_OOBINLINE on, read " + got.position() + " bytes, not the urgent byte");
        }
    }

    static void quietSelect(Selector selector, String when) throws Exception {
        ThreadMXBean threads = ManagementFactory.getThreadMXBean();
        long cpuStart = threads.getCurrentThreadCpuTime();
        long start = System.nanoTime();
        int selected = selector.select(1000);
        long waitedMillis = (System.nanoTime() - start) / 1_000_000;
        long cpuMillis = (threads.getCurrentThreadCpuTime() - cpuStart) / 1_000_000;
        require(selected == 0 && waitedMillis >= 900 && cpuMillis < 200,
            when + " and SO_OOBINLINE off, select(1000) returned " + selected + " after " + waitedMillis + " ms, using " + cpuMillis + " ms of CPU");
    }

    static String keytool(Path dir, String... args) throws Exception {
        String[] command = new String[args.length + 1];
        command[0] = Path.of(System.getProperty("java.home"), "bin", "keytool").toString();
        System.arraycopy(args, 0, command, 1, args.length);
        Process p = new ProcessBuilder(command).directory(dir.toFile()).redirectErrorStream(true).start();
        String output = new String(readAll(p.getInputStream()), StandardCharsets.UTF_8);
        require(p.waitFor(60, TimeUnit.SECONDS), "keytool did not finish");
        require(p.exitValue() == 0, "keytool " + args[0] + " exited " + p.exitValue() + ": " + output);
        return output;
    }

    static void tls() throws Exception {
        char[] password = "changeit".toCharArray();
        Path dir = Files.createTempDirectory("legacysmoke-tls");
        try {
            keytool(dir, "-genkeypair", "-alias", "smoke", "-keyalg", "RSA", "-keysize", "2048",
                "-validity", "2", "-dname", "CN=localhost", "-storetype", "PKCS12",
                "-keystore", "server.p12", "-storepass", "changeit");
            keytool(dir, "-exportcert", "-alias", "smoke", "-file", "server.cer",
                "-keystore", "server.p12", "-storepass", "changeit", "-storetype", "PKCS12");

            KeyStore serverStore = KeyStore.getInstance("PKCS12");
            try (InputStream in = Files.newInputStream(dir.resolve("server.p12"))) {
                serverStore.load(in, password);
            }
            KeyManagerFactory kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
            kmf.init(serverStore, password);

            Certificate cert;
            try (InputStream in = Files.newInputStream(dir.resolve("server.cer"))) {
                cert = CertificateFactory.getInstance("X.509").generateCertificate(in);
            }
            KeyStore trust = KeyStore.getInstance("PKCS12");
            trust.load(null, null);
            trust.setCertificateEntry("smoke", cert);
            TrustManagerFactory tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
            tmf.init(trust);

            SSLContext serverContext = SSLContext.getInstance("TLS");
            serverContext.init(kmf.getKeyManagers(), null, null);
            SSLContext clientContext = SSLContext.getInstance("TLS");
            clientContext.init(null, tmf.getTrustManagers(), null);

            InetAddress loopback = InetAddress.getByAddress(new byte[] {127, 0, 0, 1});
            Throwable[] serverFailure = new Throwable[1];
            try (SSLServerSocket server = (SSLServerSocket) serverContext.getServerSocketFactory().createServerSocket(0, 5, loopback)) {
                Thread serving = new Thread(() -> {
                    try (SSLSocket peer = (SSLSocket) server.accept()) {
                        peer.setSoTimeout(10_000);
                        peer.startHandshake();
                        InputStream in = peer.getInputStream();
                        OutputStream out = peer.getOutputStream();
                        int c = in.read();
                        out.write(c + 1);
                        out.flush();
                    } catch (Throwable t) {
                        serverFailure[0] = t;
                    }
                });
                serving.start();
                try (SSLSocket client = (SSLSocket) clientContext.getSocketFactory().createSocket(loopback, server.getLocalPort())) {
                    client.setSoTimeout(10_000);
                    client.startHandshake();
                    require(client.getSession().getProtocol().startsWith("TLS"), "negotiated " + client.getSession().getProtocol());
                    client.getOutputStream().write(41);
                    client.getOutputStream().flush();
                    int reply = client.getInputStream().read();
                    require(reply == 42, "TLS echo returned " + reply + ", wanted 42");
                }
                serving.join(10_000);
                require(!serving.isAlive(), "TLS server thread did not finish");
            }
            require(serverFailure[0] == null, "TLS server failed: " + serverFailure[0]);
        } finally {
            deleteTree(dir);
        }
    }

    static String capture(ProcessBuilder pb, byte[] stdin, int expectedExit, String what) throws Exception {
        Process p = pb.redirectErrorStream(true).start();
        if (stdin != null) {
            try (OutputStream out = p.getOutputStream()) {
                out.write(stdin);
            }
        } else {
            p.getOutputStream().close();
        }
        String output = new String(readAll(p.getInputStream()), StandardCharsets.UTF_8);
        require(p.waitFor(30, TimeUnit.SECONDS), what + " did not finish");
        require(p.exitValue() == expectedExit, what + " exited " + p.exitValue() + ", wanted " + expectedExit);
        return output;
    }

    static void process() throws Exception {
        Path helper = Path.of(System.getProperty("java.home"), "lib", "jspawnhelper");
        require(Files.isExecutable(helper), helper + " is missing or not executable");

        String echoed = capture(new ProcessBuilder("/bin/echo", "x"), null, 0, "/bin/echo x");
        require(echoed.equals("x\n"), "/bin/echo x printed " + echoed.replace("\n", "\\n"));

        String catted = capture(new ProcessBuilder("/bin/cat"), "piped".getBytes(StandardCharsets.UTF_8), 0, "/bin/cat");
        require(catted.equals("piped"), "/bin/cat printed " + catted);

        capture(new ProcessBuilder("/bin/sh", "-c", "exit 3"), null, 3, "/bin/sh -c 'exit 3'");
    }

    static void headless() {
        require(GraphicsEnvironment.isHeadless(), "GraphicsEnvironment.isHeadless() is false");
        try {
            Toolkit toolkit = Toolkit.getDefaultToolkit();
            require(toolkit != null, "Toolkit.getDefaultToolkit() returned null");
        } catch (HeadlessException expected) {
        }
    }

    // Headless text goes through sun.font.CFontManager, whose natives are in libawt_lwawt: on macOS
    // this is the run that loads lwawt and its CFont/CoreText path without a window.
    static void fonts() {
        String[] families = GraphicsEnvironment.getLocalGraphicsEnvironment().getAvailableFontFamilyNames();
        require(families.length > 0, "no font families");
        BufferedImage image = new BufferedImage(200, 60, BufferedImage.TYPE_INT_RGB);
        Graphics2D g = image.createGraphics();
        try {
            g.setColor(Color.WHITE);
            g.fillRect(0, 0, 200, 60);
            g.setColor(Color.BLACK);
            g.setFont(new Font(Font.SANS_SERIF, Font.PLAIN, 24));
            g.drawString("Mavericks", 10, 40);
        } finally {
            g.dispose();
        }
        int changed = 0;
        for (int y = 0; y < 60; y++) {
            for (int x = 0; x < 200; x++) {
                if ((image.getRGB(x, y) & 0xffffff) != 0xffffff) {
                    changed++;
                }
            }
        }
        require(changed > 0, "drawString changed no pixel (" + families.length + " font families)");
    }

    static void https() throws Exception {
        HttpClient client = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(20))
            .followRedirects(HttpClient.Redirect.NORMAL)
            .build();
        HttpRequest request = HttpRequest.newBuilder(URI.create("https://github.com"))
            .timeout(Duration.ofSeconds(30))
            .GET()
            .build();
        HttpResponse<Void> response = client.send(request, HttpResponse.BodyHandlers.discarding());
        require(response.statusCode() == 200, "GET https://github.com returned " + response.statusCode());
    }
}
