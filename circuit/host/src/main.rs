use std::path::PathBuf;

use alloy_sol_types::SolValue;
use clap::Parser;
use methods::{WINDY_GUEST_ELF, WINDY_GUEST_ID};
use risc0_zkvm::{default_prover, ExecutorEnv};
use windy_circuit_core::{WindyInput, WindyJournalSol};

const DEFAULT_PROGRAM: &str = include_str!("../../programs/hello.wnd");

/// Generate a Risc Zero proof of running a windy-lang program in the zkVM guest.
#[derive(Parser)]
#[command(version, about)]
struct Cli {
    /// Recipient Ethereum address that the on-chain minter will mint to.
    /// Bound into the proof so a third party cannot replay it for someone else.
    #[arg(long, value_parser = parse_address)]
    recipient: [u8; 20],

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

fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::filter::EnvFilter::from_default_env())
        .init();

    let cli = Cli::parse();

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
        recipient: cli.recipient,
        nonce,
    };

    let env = ExecutorEnv::builder()
        .write(&input)
        .unwrap()
        .build()
        .unwrap();

    let prover = default_prover();
    let prove_info = prover.prove(env, WINDY_GUEST_ELF).unwrap();
    let receipt = prove_info.receipt;

    let journal = WindyJournalSol::abi_decode_validate(&receipt.journal.bytes)
        .expect("guest journal must abi-decode as WindyJournalSol");

    println!("guest journal:");
    println!("  recipient:    0x{}", hex::encode(journal.recipient));
    println!("  nonce:        0x{}", hex::encode(journal.nonce));
    println!("  program_hash: 0x{}", hex::encode(journal.programHash));
    println!("  output_hash:  0x{}", hex::encode(journal.outputHash));
    println!(
        "  exit_code:    {} ({})",
        journal.exitCode,
        exit_label(journal.exitCode)
    );
    println!("  steps:        {}", journal.steps);
    println!("  raw bytes:    {} (abi-encoded)", receipt.journal.bytes.len());

    receipt
        .verify(WINDY_GUEST_ID)
        .expect("receipt failed verification");
    println!("receipt verified");
}
