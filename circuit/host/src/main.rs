use std::path::PathBuf;

use alloy_sol_types::SolValue;
use clap::Parser;
use methods::{WINDY_GUEST_ELF, WINDY_GUEST_ID};
use risc0_zkvm::{default_prover, sha::Digest, ExecutorEnv, ProverOpts};
use windy_circuit_core::{WindyInput, WindyJournalSol};

const DEFAULT_PROGRAM: &str = include_str!("../../programs/hello.wnd");

/// Generate a Risc Zero proof of running a windy-lang program in the zkVM guest.
#[derive(Parser)]
#[command(version, about)]
struct Cli {
    /// Print the guest IMAGE_ID (bytes32, suitable for ZkExecutionMinter
    /// deployment) and exit. No proof is generated.
    #[arg(long)]
    print_image_id: bool,

    /// Recipient Ethereum address that the on-chain minter will mint to.
    /// Required unless `--print-image-id`. Bound into the proof so a third
    /// party cannot replay it for someone else.
    #[arg(long, value_parser = parse_address)]
    recipient: Option<[u8; 20]>,

    /// Optional 32-byte nonce, hex-encoded. Random if omitted.
    /// The on-chain minter uses this to dedupe replays.
    #[arg(long, value_parser = parse_b256)]
    nonce: Option<[u8; 32]>,

    /// Path to a windy-lang source file. If omitted, the bundled `hello.wnd` is used.
    #[arg(long, value_name = "PATH")]
    program_file: Option<PathBuf>,

    /// PRNG seed for the windy VM (controls outcomes of random opcodes).
    #[arg(long, default_value_t = 0)]
    seed: u64,

    /// Step (tick) cap before the VM aborts with `MaxSteps`.
    #[arg(long, default_value_t = 100_000)]
    max_steps: u64,

    /// Optional file to feed as stdin to the windy program.
    #[arg(long, value_name = "PATH")]
    stdin_file: Option<PathBuf>,
}

fn parse_address(s: &str) -> Result<[u8; 20], String> {
    let s = s.strip_prefix("0x").unwrap_or(s);
    let bytes = hex::decode(s).map_err(|e| format!("invalid hex: {e}"))?;
    if bytes.len() != 20 {
        return Err(format!(
            "expected 20 bytes (40 hex chars), got {}",
            bytes.len()
        ));
    }
    let mut arr = [0u8; 20];
    arr.copy_from_slice(&bytes);
    Ok(arr)
}

fn parse_b256(s: &str) -> Result<[u8; 32], String> {
    let s = s.strip_prefix("0x").unwrap_or(s);
    let bytes = hex::decode(s).map_err(|e| format!("invalid hex: {e}"))?;
    if bytes.len() != 32 {
        return Err(format!(
            "expected 32 bytes (64 hex chars), got {}",
            bytes.len()
        ));
    }
    let mut arr = [0u8; 32];
    arr.copy_from_slice(&bytes);
    Ok(arr)
}

fn exit_label(code: i32) -> &'static str {
    match code {
        0 => "Ok",
        124 => "MaxSteps",
        134 => "Trap",
        _ => "Unknown",
    }
}

/// Pretty-print the `hardOpcodeBitmap` field as a comma-separated list
/// of glyph names. Bit assignments mirror `WindyJournalSol`'s docstring.
fn format_hard_opcodes(bitmap: u16) -> String {
    const NAMES: [(u16, &str); 10] = [
        (1 << 0, "t"),
        (1 << 1, "p"),
        (1 << 2, "g"),
        (1 << 3, "_"),
        (1 << 4, "|"),
        (1 << 5, "≫"),
        (1 << 6, "≪"),
        (1 << 7, "~"),
        (1 << 8, "#"),
        (1 << 9, "\""),
    ];
    let used: Vec<&str> = NAMES
        .iter()
        .filter(|(bit, _)| bitmap & bit != 0)
        .map(|(_, name)| *name)
        .collect();
    if used.is_empty() {
        "—".to_string()
    } else {
        used.join(" ")
    }
}

fn image_id_bytes() -> [u8; 32] {
    Digest::from(WINDY_GUEST_ID).into()
}

fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::filter::EnvFilter::from_default_env())
        .init();

    let cli = Cli::parse();

    if cli.print_image_id {
        println!("0x{}", hex::encode(image_id_bytes()));
        return;
    }

    let recipient = cli
        .recipient
        .expect("--recipient is required (or pass --print-image-id)");

    let program = match cli.program_file {
        Some(path) => std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("failed to read program file {}: {e}", path.display())),
        None => DEFAULT_PROGRAM.to_string(),
    };

    let stdin = match cli.stdin_file {
        Some(path) => std::fs::read(&path)
            .unwrap_or_else(|e| panic!("failed to read stdin file {}: {e}", path.display())),
        None => Vec::new(),
    };

    let nonce = cli.nonce.unwrap_or_else(rand::random);

    let input = WindyInput {
        program,
        seed: cli.seed,
        max_steps: cli.max_steps,
        stdin,
        recipient,
        nonce,
    };

    let env = ExecutorEnv::builder()
        .write(&input)
        .unwrap()
        .build()
        .unwrap();

    let prover = default_prover();
    // Request a Groth16 receipt directly. With the local prover this
    // requires Docker (the STARK→Groth16 wrap runs in a container);
    // with Bonsai it's the same opts knob the cloud honors.
    let prove_info = prover
        .prove_with_opts(env, WINDY_GUEST_ELF, &ProverOpts::groth16())
        .unwrap();
    let receipt = prove_info.receipt;

    let journal = WindyJournalSol::abi_decode_validate(&receipt.journal.bytes)
        .expect("guest journal must abi-decode as WindyJournalSol");

    println!("guest journal:");
    println!("  recipient:          0x{}", hex::encode(journal.recipient));
    println!("  nonce:              0x{}", hex::encode(journal.nonce));
    println!("  program_hash:       0x{}", hex::encode(journal.programHash));
    println!("  output_hash:        0x{}", hex::encode(journal.outputHash));
    println!(
        "  exit_code:          {} ({})",
        journal.exitCode,
        exit_label(journal.exitCode)
    );
    println!("  steps:              {}", journal.steps);
    println!("  ─ Phase 2 metrics ─");
    println!(
        "  hard_opcode_bitmap: 0x{:04x}  ({})",
        journal.hardOpcodeBitmap,
        format_hard_opcodes(journal.hardOpcodeBitmap)
    );
    println!("  max_alive_ips:      {}", journal.maxAliveIps);
    println!("  spawned_ips:        {}", journal.spawnedIps);
    println!("  grid_writes:        {}", journal.gridWrites);
    println!("  branch_count:       {}", journal.branchCount);
    println!("  visited_cells:      {}  (trace-truth code size)", journal.visitedCells);
    println!("  effective_cells:    {}  (static parse, includes punctuation in comments)", journal.effectiveCells);
    println!("  total_grid_cells:   {}", journal.totalGridCells);
    println!("  raw bytes:          {} (abi-encoded)", receipt.journal.bytes.len());

    receipt
        .verify(WINDY_GUEST_ID)
        .expect("receipt failed verification");
    println!("receipt verified");

    println!();
    match receipt.inner.groth16() {
        Ok(groth16) => {
            // The on-chain RiscZeroVerifierRouter dispatches by the
            // first 4 bytes of `seal`, which must equal the first 4
            // bytes of `verifier_parameters` — the same prefix
            // risc0-ethereum-contracts' `encode_seal()` helper adds.
            // Doing it manually here so the printed `seal:` line is
            // ready to paste straight into `cast send`.
            let selector = &groth16.verifier_parameters.as_bytes()[..4];
            let mut full_seal = Vec::with_capacity(selector.len() + groth16.seal.len());
            full_seal.extend_from_slice(selector);
            full_seal.extend_from_slice(&groth16.seal);

            println!("on-chain payload (paste into `cast send`):");
            println!("  image_id: 0x{}", hex::encode(image_id_bytes()));
            println!("  selector: 0x{}", hex::encode(selector));
            println!("  seal:     0x{}", hex::encode(&full_seal));
            println!("  journal:  0x{}", hex::encode(&receipt.journal.bytes));
        }
        Err(_) => {
            println!("on-chain payload: not available — the local prover produced a");
            println!("STARK receipt, which is too large to verify on chain. Set");
            println!("BONSAI_API_URL + BONSAI_API_KEY (or RISC0_PROVER=bonsai) and");
            println!("re-run to get a Groth16 seal suitable for ZkExecutionMinter.mint().");
        }
    }
}
