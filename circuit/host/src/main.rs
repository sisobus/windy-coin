use std::path::PathBuf;

use clap::Parser;
use methods::{WINDY_GUEST_ELF, WINDY_GUEST_ID};
use risc0_zkvm::{default_prover, ExecutorEnv};
use serde::{Deserialize, Serialize};

const DEFAULT_PROGRAM: &str = include_str!("../../programs/hello.wnd");

#[derive(Serialize, Deserialize)]
pub struct WindyInput {
    pub program: String,
    pub seed: u64,
    pub max_steps: u64,
    pub stdin: Vec<u8>,
}

#[derive(Serialize, Deserialize)]
pub struct WindyJournal {
    pub program_hash: [u8; 32],
    pub output_hash: [u8; 32],
    pub exit_code: i32,
    pub steps: u64,
}

/// Generate a Risc Zero proof of running a windy-lang program in the zkVM guest.
#[derive(Parser)]
#[command(version, about)]
struct Cli {
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

    let input = WindyInput {
        program,
        seed: cli.seed,
        max_steps: cli.max_steps,
        stdin,
    };

    let env = ExecutorEnv::builder()
        .write(&input)
        .unwrap()
        .build()
        .unwrap();

    let prover = default_prover();
    let prove_info = prover.prove(env, WINDY_GUEST_ELF).unwrap();
    let receipt = prove_info.receipt;

    let journal: WindyJournal = receipt
        .journal
        .decode()
        .expect("guest journal must decode as WindyJournal");

    println!("guest journal:");
    println!("  program_hash: 0x{}", hex::encode(journal.program_hash));
    println!("  output_hash:  0x{}", hex::encode(journal.output_hash));
    println!(
        "  exit_code:    {} ({})",
        journal.exit_code,
        exit_label(journal.exit_code)
    );
    println!("  steps:        {}", journal.steps);

    receipt
        .verify(WINDY_GUEST_ID)
        .expect("receipt failed verification");
    println!("receipt verified");
}
