import java.lang.management.ManagementFactory;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.concurrent.CountDownLatch;

// Java8-compatible, dependency-free real JVM shutdown/persistence fixture.
public final class Workload {
    public static void main(String[] args) throws Exception {
        final Path state = Paths.get("/kubedoop/run/java-state");
        final int count = Files.exists(state)
            ? Integer.parseInt(new String(Files.readAllBytes(state), StandardCharsets.UTF_8).trim()) : 0;
        final String pid = ManagementFactory.getRuntimeMXBean().getName().split("@", 2)[0];
        Files.write(Paths.get("/kubedoop/run/java-pid"), pid.getBytes(StandardCharsets.UTF_8));
        Runtime.getRuntime().addShutdownHook(new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    Files.write(state, Integer.toString(count + 1).getBytes(StandardCharsets.UTF_8));
                    System.out.println("TEST_JAVA_FLUSHED");
                } catch (Exception failure) {
                    failure.printStackTrace(System.err);
                }
            }
        }, "persist-on-shutdown"));
        System.out.println("TEST_JAVA_READY");
        if (args.length != 0 && "exit42".equals(args[0])) {
            System.exit(42);
        }
        new CountDownLatch(1).await();
    }
}
