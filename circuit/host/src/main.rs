use methods::{WINDY_GUEST_ELF, WINDY_GUEST_ID};
use risc0_zkvm::{default_prover, ExecutorEnv};
use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize)]
pub struct WindyJournal {
    pub program_hash: [u8; 32],
    pub output_hash: [u8; 32],
    pub exit_code: i32,
    pub steps: u64,
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

    let env = ExecutorEnv::builder().build().unwrap();

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
