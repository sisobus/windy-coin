use alloy_primitives::{Address, B256};
use alloy_sol_types::SolValue;
use risc0_zkvm::guest::env;
use sha2::{Digest, Sha256};
use windy::{parse, ExitCode, Vm};
use windy_circuit_core::{WindyInput, WindyJournalSol};

fn main() {
    let input: WindyInput = env::read();

    let (grid, _scan_text) = parse(&input.program);

    // Snapshot grid shape *before* execution. `g`/`p` can mutate the
    // grid mid-run, but the policy grades on the source layout the
    // miner submitted, not on what the program ended up looking like.
    let effective_cells: u32 = grid.effective_cells();
    let total_grid_cells: u32 = grid.total_grid_cells();

    let mut vm = Vm::new(grid, Some(input.seed), Some(input.max_steps));

    let mut stdin: &[u8] = &input.stdin;
    let mut stdout: Vec<u8> = Vec::new();
    let mut stderr: Vec<u8> = Vec::new();

    let exit: ExitCode = vm.run(&mut stdin, &mut stdout, &mut stderr);

    let program_hash: [u8; 32] = Sha256::digest(input.program.as_bytes()).into();
    let output_hash: [u8; 32] = Sha256::digest(&stdout).into();

    let m = vm.metrics;

    let journal = WindyJournalSol {
        recipient: Address::from(input.recipient),
        nonce: B256::from(input.nonce),
        programHash: B256::from(program_hash),
        outputHash: B256::from(output_hash),
        exitCode: exit.code(),
        steps: vm.steps,
        hardOpcodeBitmap: m.hard_opcode_bitmap,
        maxAliveIps: m.max_alive_ips,
        spawnedIps: m.spawned_ips,
        gridWrites: m.grid_writes,
        branchCount: m.branch_count,
        visitedCells: m.visited_cells,
        effectiveCells: effective_cells,
        totalGridCells: total_grid_cells,
    };

    env::commit_slice(&journal.abi_encode());
}
