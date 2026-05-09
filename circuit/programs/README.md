# windy-coin sample programs

Hand-picked windy-lang programs from [`sisobus/windy/examples`](https://github.com/sisobus/windy/tree/main/examples) plus the bundled hello.

Each program is run end-to-end through the zkVM guest with `--seed 0
--max-steps 100000` and an arbitrary fixed recipient/nonce. The
metrics in the table below are the v2 journal fields fed to the
[Phase 2 mining policy](../../docs/PHASE-2-MINING.md) — `visited` is
the trace-truth code size (cells the IP actually executed at; comments
and unreachable signature blocks don't count), and the others come
from the windy-lang `metrics` feature.

The metric numbers are pinned to the **current guest** — if either
the guest source or the windy-lang version changes, `IMAGE_ID`
changes and the regression baseline is expected to drift.

| Program           | Bytes | Steps | visited | maxIPs | spawn | writes | branch | hard-ops    | exit |
| ----------------- | ----: | ----: | ------: | -----: | ----: | -----: | -----: | :---------- | :--- |
| `hello.wnd`       |    30 |    29 |      29 |      1 |     0 |      0 |      0 | `"`         | Ok   |
| `hello_winds.wnd` |   121 |   107 |      30 |      1 |     0 |      0 |     14 | `_ # "`     | Ok   |
| `sum_winds.wnd`   |    97 |    24 |      24 |      2 |     1 |      0 |      0 | `t`         | Ok   |
| `hi_windy.wnd`    |   216 |   102 |      49 |      2 |     1 |      0 |     10 | `t _ # "`   | Ok   |
| `fib.wnd`         |   277 |   764 |     100 |      1 |     0 |     33 |     10 | `p g \|`    | Ok   |
| `factorial.wnd`   |  1031 |   912 |     113 |      1 |     0 |     22 |     10 | `p g \|`    | Ok   |
| `puzzle_hard.wnd` |  3431 |    18 |      15 |      4 |     3 |      0 |      0 | `t`         | Ok   |

Output digests (SHA-256 of stdout, deterministic for these programs since none use `~`):

| Program           | `output_hash`                                                          |
| ----------------- | ---------------------------------------------------------------------- |
| `hello.wnd`       | `0xdffd6021bb2bd5b0af676290809ec3a53191dd81c7f70a4b28688a362182986f` * |
| `hello_winds.wnd` | `0xdffd6021bb2bd5b0af676290809ec3a53191dd81c7f70a4b28688a362182986f` * |
| `hi_windy.wnd`    | `0x5b4189a984989aeb2ec768645241c8b7e64d0dee3a2f256cd6131b55c60e67d3`   |
| `sum_winds.wnd`   | `0xcf0eb12f371a790871ed93abd79781ab182f16f5a36d38895a19458fb7a71c8e`   |
| `fib.wnd`         | `0xc8337b3ac92c650dfba406dbb2d4598465bb2537e6d2120cbd84f62606c41185`   |
| `factorial.wnd`   | `0xb610a2b561fc930a0fc146987a95ef93cde26a00eeb6af567748e043c6e18aa4`   |
| `puzzle_hard.wnd` | `0xa3a2a5f918f186fbf86c27f190a7b1fc83fb7c3ac0efbc82d4239c82d06c54ef`   |

\* `hello.wnd` and `hello_winds.wnd` produce the same `output_hash` because they
both print exactly the string `Hello, World!` — `output_hash` is `sha256(stdout)`,
not a function of the source code, so two programs with different layouts but
identical output collide here. (`program_hash` differs.)

## What each program exercises in the guest

- **`hello.wnd`** — string-mode push (`"…"`), 13 `,` opcodes that pop & print as
  characters, `@` halt. Single IP, no grid memory, no math beyond stack. Tiny
  smoke test for the basic VM loop.

- **`hello_winds.wnd`** — same output as `hello.wnd` but the IP travels over a
  2-D grid via `↓` / `→` / `←` arrows (true to windy's "code flows like wind"
  identity). Exercises the grid+wind IP machinery.

- **`hi_windy.wnd`** — heavily 2-D, wind-routed program with branching arrows
  (`↘` `↗` `↙` `↖`). Hits more of the parser/grid code path than the others.

- **`sum_winds.wnd`** — multi-IP via `t` (spawn). Useful because windy's
  collision/merge logic only fires when 2+ IPs are alive. Step count is small
  (24) but the run-loop visits a wider chunk of the VM than the single-IP
  programs.

- **`fib.wnd`** — Fibonacci via grid memory (`g`/`p` load/store). Repeated
  inner loop (~12 ticks per Fibonacci number generated) demonstrates that the
  zkVM holds up across hundreds of steps without blowing prover time.

- **`factorial.wnd`** — first 10 factorials, also via grid memory. Last few
  values (`9!`, `10!`) overflow `i64`, so this exercises windy's `BigInt` stack
  inside the zkVM. Slowest of the bunch (912 steps) but still < 1s of guest
  execution.

## Reproducing

```bash
cd circuit
cargo run --release -p host -- \
  --recipient 0x0000000000000000000000000000000000000001 \
  --nonce 0x0000000000000000000000000000000000000000000000000000000000000001 \
  --program-file programs/<name>.wnd
```

Different `--seed` values can change outputs only for programs that hit a
random opcode (none of the above do — they're all deterministic regardless of
seed). The `--max-steps 100000` default is well above the highest tick count
in this set (912 for `factorial.wnd`), so none of these will ever trip
`ExitCode::MaxSteps`.

To witness the trap (`exit_code = 134`) and max-steps (`exit_code = 124`)
branches, write a small program that uses `CALM` (the trap-on-speed-1 op) or
loop forever — both reproduce against the same guest without needing changes
to the host.
