use risc0_zkvm::guest::env;
use sha2::{Digest, Sha256};
use windy::{parse, ExitCode, Vm};
use windy_circuit_core::{WindyInput, WindyJournal};

fn main() {
    let input: WindyInput = env::read();

    let (grid, _scan_text) = parse(&input.program);
    let mut vm = Vm::new(grid, Some(input.seed), Some(input.max_steps));

    let mut stdin: &[u8] = &input.stdin;
    let mut stdout: Vec<u8> = Vec::new();
    let mut stderr: Vec<u8> = Vec::new();

    let exit: ExitCode = vm.run(&mut stdin, &mut stdout, &mut stderr);

    let program_hash: [u8; 32] = Sha256::digest(input.program.as_bytes()).into();
    let output_hash: [u8; 32] = Sha256::digest(&stdout).into();

    let journal = WindyJournal {
        program_hash,
        output_hash,
        exit_code: exit.code(),
        steps: vm.steps,
    };

    env::commit(&journal);
}
