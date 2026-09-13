package bench;

import org.openjdk.jmh.annotations.*;
import org.openjdk.jmh.infra.Blackhole;
import java.util.*;
import java.util.concurrent.TimeUnit;

/**
 * Template: replace the method bodies to measure your own code.
 * What it demonstrates: the time AND allocation difference between two
 * implementations that do the same work.
 */
@BenchmarkMode(Mode.AverageTime)
@OutputTimeUnit(TimeUnit.MICROSECONDS)
@State(Scope.Benchmark)
@Fork(value = 2, jvmArgs = {"-Xms1g", "-Xmx1g"})
@Warmup(iterations = 5, time = 1)
@Measurement(iterations = 10, time = 1)
public class SpeedBenchmark {

    private List<String> data;

    @Setup(Level.Trial)
    public void setup() {
        data = new ArrayList<>();
        for (int i = 0; i < 10_000; i++) data.add("record-" + i);
    }

    /** OLD: string concat in a loop -> a new StringBuilder + copy on every step */
    @Benchmark
    public void oldWay(Blackhole bh) {
        String s = "";
        for (String v : data) s += v + ";";
        bh.consume(s);                 // Blackhole IS REQUIRED: otherwise JIT deletes the whole loop
    }

    /** NEW: a single StringBuilder, pre-sized */
    @Benchmark
    public void newWay(Blackhole bh) {
        StringBuilder sb = new StringBuilder(data.size() * 12);
        for (String v : data) sb.append(v).append(';');
        bh.consume(sb.toString());
    }
}
