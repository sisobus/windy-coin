use risc0_zkvm::guest::env;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use windy::{parse, ExitCode, Vm};

const WINDY_SOURCE: &str = include_str!("hello.wnd");
const SEED: u64 = 0;
const MAX_STEPS: u64 = 100_000;

#[derive(Serialize, Deserialize)]
pub struct WindyJournal {
    pub program_hash: [u8; 32],
    pub output_hash: [u8; 32],
    pub exit_code: i32,
    pub steps: u64,
}

fn main() {
    let (grid, _scan_text) = parse(WINDY_SOURCE);
    let mut vm = Vm::new(grid, Some(SEED), Some(MAX_STEPS));

    let mut stdin: &[u8] = &[];
    let mut stdout: Vec<u8> = Vec::new();
    let mut stderr: Vec<u8> = Vec::new();

    let exit: ExitCode = vm.run(&mut stdin, &mut stdout, &mut stderr);

    let program_hash: [u8; 32] = Sha256::digest(WINDY_SOURCE.as_bytes()).into();
    let output_hash: [u8; 32] = Sha256::digest(&stdout).into();

    let journal = WindyJournal {
        program_hash,
        output_hash,
        exit_code: exit.code(),
        steps: vm.steps,
    };

    env::commit(&journal);
}
