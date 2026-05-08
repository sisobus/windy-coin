use methods::{WINDY_GUEST_ELF, WINDY_GUEST_ID};
use risc0_zkvm::{default_prover, ExecutorEnv};

fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::filter::EnvFilter::from_default_env())
        .init();

    let env = ExecutorEnv::builder().build().unwrap();

    let prover = default_prover();
    let prove_info = prover.prove(env, WINDY_GUEST_ELF).unwrap();
    let receipt = prove_info.receipt;

    let message = std::str::from_utf8(&receipt.journal.bytes)
        .expect("guest journal must be valid utf-8");
    println!("guest journal: {message}");

    receipt
        .verify(WINDY_GUEST_ID)
        .expect("receipt failed verification");
    println!("receipt verified");
}
