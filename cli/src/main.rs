//! `windy-mine` — end-to-end miner CLI for the WNDY (windy-coin) token.
//!
//! Two modes:
//!   - default       — full Risc Zero Groth16 proof + `mint(seal,journal)` tx
//!   - `--dry-run`   — zkVM execute only + on-chain `computeScore` grading
//!
//! Designed to also work as a plugin for windy-lang's CLI: typing
//! `windy mine path/foo.wnd` triggers windy's `external_subcommand` hook,
//! which execs `windy-mine path/foo.wnd` — identical UX.
//!
//! The proving and zkVM execution run in-process (this binary depends
//! on the same `methods` crate the host CLI does, so `IMAGE_ID` stays
//! pinned by `Cargo.lock`). Chain calls (computeScore, mint) shell out
//! to Foundry's `cast` so keystore semantics match what `forge script`
//! and `cast send` users already expect.

use std::path::PathBuf;
use std::process::{Command, ExitCode};

use alloy_primitives::keccak256;
use alloy_sol_types::SolValue;
use anyhow::{anyhow, bail, Context, Result};
use clap::Parser;
use methods::{WINDY_GUEST_ELF, WINDY_GUEST_ID};
use risc0_zkvm::{default_executor, default_prover, ExecutorEnv, ProverOpts};
use windy_circuit_core::{WindyInput, WindyJournalSol};

const DEFAULT_MINTER: &str = "0xc566ab14616662ae92095a72a8cc23bf62b6ff02";
const DEFAULT_WNDY: &str = "0x8c64a92e3a12f5ca4050b5fb90804bd24cd653ca";
const DEFAULT_RPC: &str = "https://mainnet.base.org";
const DEFAULT_ACCOUNT: &str = "deployer-mainnet";

const COMPUTE_SCORE_SIG: &str =
    "computeScore((address,bytes32,bytes32,bytes32,int32,uint64,uint16,uint64,uint64,uint64,uint64,uint64,uint32,uint32))";

const MIN_VISITED: u64 = 10;
const MAX_VISITED: u64 = 1500;

#[derive(Parser)]
#[command(
    name = "windy-mine",
    version,
    about = "Mine WNDY: prove a windy-lang run with Risc Zero, mint on Base mainnet.",
    long_about = "Mine WNDY by running a windy-lang program through the Risc Zero zkVM \
                  and submitting the resulting proof to ZkExecutionMinterV2 on Base mainnet. \
                  Pass --dry-run to skip Groth16/mint and just predict the score + tier."
)]
struct Cli {
    /// Path to the .wnd source file.
    program: PathBuf,

    /// Skip Groth16 wrap and mint tx. Predicts score + tier in ~seconds.
    #[arg(long)]
    dry_run: bool,

    /// Override recipient address (defaults to the address of `--account`).
    #[arg(long)]
    recipient: Option<String>,

    /// Foundry keystore alias used both to derive the recipient and to sign the mint tx.
    #[arg(long, default_value = DEFAULT_ACCOUNT)]
    account: String,

    /// ZkExecutionMinterV2 contract address.
    #[arg(long, default_value = DEFAULT_MINTER)]
    minter: String,

    /// Windy ERC-20 token address.
    #[arg(long, default_value = DEFAULT_WNDY)]
    wndy: String,

    /// Base RPC URL.
    #[arg(long, default_value = DEFAULT_RPC)]
    rpc: String,

    /// windy VM tick cap.
    #[arg(long, default_value_t = 100_000)]
    max_steps: u64,

    /// windy VM PRNG seed.
    #[arg(long, default_value_t = 0)]
    seed: u64,

    /// Fixed 32-byte hex nonce (random if unset).
    #[arg(long)]
    nonce: Option<String>,
}

fn main() -> ExitCode {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::filter::EnvFilter::from_default_env())
        .init();

    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("\nerror: {e:#}");
            ExitCode::from(1)
        }
    }
}

fn run() -> Result<()> {
    let cli = Cli::parse();

    let recipient = match cli.recipient.as_ref() {
        Some(r) => r.clone(),
        None => derive_recipient(&cli.account)?,
    };
    let recipient_bytes = parse_address(&recipient)?;
    let nonce_bytes = match cli.nonce.as_ref() {
        Some(n) => parse_b256(n)?,
        None => rand::random(),
    };

    let source = std::fs::read_to_string(&cli.program)
        .with_context(|| format!("failed to read {}", cli.program.display()))?;

    let input = WindyInput {
        program: source,
        seed: cli.seed,
        max_steps: cli.max_steps,
        stdin: Vec::new(),
        recipient: recipient_bytes,
        nonce: nonce_bytes,
    };

    print_banner(&cli, &recipient, cli.dry_run);

    let env = ExecutorEnv::builder()
        .write(&input)
        .map_err(|e| anyhow!("ExecutorEnv build: {e:?}"))?
        .build()
        .map_err(|e| anyhow!("ExecutorEnv build: {e:?}"))?;

    if cli.dry_run {
        return run_dry(&cli, env);
    }

    check_docker()?;
    run_real(&cli, env, &recipient)
}

fn run_dry(cli: &Cli, env: ExecutorEnv) -> Result<()> {
    eprintln!("▶ Executing zkVM guest (no proof, ~seconds)...\n");

    let session = default_executor()
        .execute(env, WINDY_GUEST_ELF)
        .map_err(|e| anyhow!("zkVM execution failed: {e:?}"))?;
    let journal_bytes = session.journal.bytes;
    let journal = WindyJournalSol::abi_decode_validate(&journal_bytes)
        .context("journal must abi-decode as WindyJournalSol")?;

    print_journal(&journal, journal_bytes.len());

    let (score_x1000, tier) = compute_score_on_chain(&cli.rpc, &cli.minter, &journal_bytes)?;
    print_grade(score_x1000, tier);
    check_eligibility(journal.visitedCells, tier);

    eprintln!();
    if tier > 0 && in_visited_range(journal.visitedCells) {
        eprintln!("Looks mintable. Re-run without --dry-run to claim it.");
    } else {
        eprintln!("Not mintable as-is. Adjust the program and re-run.");
    }
    Ok(())
}

fn run_real(cli: &Cli, env: ExecutorEnv, recipient: &str) -> Result<()> {
    eprintln!("▶ Generating Risc Zero Groth16 proof — 5~10 min on first build.");
    eprintln!("  Keystore password NOT needed during this step.\n");

    let prove_info = default_prover()
        .prove_with_opts(env, WINDY_GUEST_ELF, &ProverOpts::groth16())
        .map_err(|e| anyhow!("proof generation failed: {e:?}"))?;
    let receipt = prove_info.receipt;

    let journal = WindyJournalSol::abi_decode_validate(&receipt.journal.bytes)
        .context("journal must abi-decode as WindyJournalSol")?;
    print_journal(&journal, receipt.journal.bytes.len());

    receipt
        .verify(WINDY_GUEST_ID)
        .map_err(|e| anyhow!("receipt failed local verification: {e:?}"))?;
    eprintln!("receipt verified locally\n");

    let groth16 = receipt
        .inner
        .groth16()
        .map_err(|_| anyhow!("prover returned a STARK receipt, not Groth16 (Docker needed)"))?;

    // Selector prefix dispatches via Base's RiscZeroVerifierRouter — same
    // logic as risc0-ethereum-contracts' encode_seal().
    let selector = &groth16.verifier_parameters.as_bytes()[..4];
    let mut full_seal = Vec::with_capacity(selector.len() + groth16.seal.len());
    full_seal.extend_from_slice(selector);
    full_seal.extend_from_slice(&groth16.seal);
    let seal_hex = format!("0x{}", hex::encode(&full_seal));
    let journal_hex = format!("0x{}", hex::encode(&receipt.journal.bytes));

    let (score_x1000, tier) = compute_score_on_chain(&cli.rpc, &cli.minter, &receipt.journal.bytes)?;
    print_grade(score_x1000, tier);
    check_eligibility(journal.visitedCells, tier);

    if tier == 0 || !in_visited_range(journal.visitedCells) {
        bail!("mint would revert with the eligibility check above; not submitting tx");
    }

    eprintln!();
    eprintln!("════════════════════════════════════════════════════════════════");
    eprintln!("  Submitting mint tx (keystore password will be prompted)");
    eprintln!("════════════════════════════════════════════════════════════════\n");

    let status = Command::new("cast")
        .args([
            "send",
            &cli.minter,
            "mint(bytes,bytes)",
            &seal_hex,
            &journal_hex,
            "--rpc-url",
            &cli.rpc,
            "--account",
            &cli.account,
        ])
        .status()
        .context("failed to run `cast send`")?;
    if !status.success() {
        bail!("cast send returned non-zero status");
    }

    let balance = cast_balance(&cli.rpc, &cli.wndy, recipient)?;
    let supply = cast_total_supply(&cli.rpc, &cli.wndy)?;

    eprintln!();
    eprintln!("════════════════════════════════════════════════════════════════");
    eprintln!("  ✅ Mint complete");
    eprintln!("════════════════════════════════════════════════════════════════");
    eprintln!("  {recipient}");
    eprintln!("    balance:      {balance} WNDY");
    eprintln!("  totalSupply:    {supply} WNDY (out of 21,000,000 cap)");
    Ok(())
}

// ────────────────────────────────────────────────────────────────────────────
// On-chain helpers

fn compute_score_on_chain(rpc: &str, minter: &str, journal_bytes: &[u8]) -> Result<(u64, u8)> {
    let selector = &keccak256(COMPUTE_SCORE_SIG.as_bytes())[..4];
    let mut calldata = Vec::with_capacity(4 + journal_bytes.len());
    calldata.extend_from_slice(selector);
    calldata.extend_from_slice(journal_bytes);
    let calldata_hex = format!("0x{}", hex::encode(&calldata));

    eprintln!("▶ Grading on-chain via computeScore...");

    // cast call <to> <data> --rpc-url <rpc>
    let output = Command::new("cast")
        .args(["call", minter, &calldata_hex, "--rpc-url", rpc])
        .output()
        .context("failed to run `cast call`")?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        bail!("cast call failed:\n{stderr}");
    }
    let raw = String::from_utf8(output.stdout)?.trim().to_string();
    decode_score_result(&raw)
}

fn decode_score_result(hex_str: &str) -> Result<(u64, u8)> {
    let h = hex_str.trim_start_matches("0x");
    if h.len() < 128 {
        bail!("computeScore result too short: {hex_str}");
    }
    let score_hex = &h[..64];
    let tier_hex = &h[64..128];
    let score = u64::from_str_radix(score_hex.trim_start_matches('0'), 16).unwrap_or(0);
    let tier = u8::from_str_radix(tier_hex.trim_start_matches('0'), 16).unwrap_or(0);
    Ok((score, tier))
}

fn cast_balance(rpc: &str, wndy: &str, addr: &str) -> Result<String> {
    let output = Command::new("cast")
        .args(["call", wndy, "balanceOf(address)(uint256)", addr, "--rpc-url", rpc])
        .output()
        .context("failed to run `cast call balanceOf`")?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        bail!("cast call balanceOf failed:\n{stderr}");
    }
    let raw = String::from_utf8(output.stdout)?;
    // Output may be like "1000000000000000000 [1e18]" — take first field.
    let first = raw.split_whitespace().next().unwrap_or("0").to_string();
    let formatted = Command::new("cast")
        .args(["--from-wei", &first])
        .output()
        .context("failed to format wei")?;
    Ok(String::from_utf8(formatted.stdout)?.trim().to_string())
}

fn cast_total_supply(rpc: &str, wndy: &str) -> Result<String> {
    let output = Command::new("cast")
        .args(["call", wndy, "totalSupply()(uint256)", "--rpc-url", rpc])
        .output()
        .context("failed to run `cast call totalSupply`")?;
    if !output.status.success() {
        bail!("cast call totalSupply failed");
    }
    let raw = String::from_utf8(output.stdout)?;
    let first = raw.split_whitespace().next().unwrap_or("0").to_string();
    let formatted = Command::new("cast")
        .args(["--from-wei", &first])
        .output()
        .context("failed to format wei")?;
    Ok(String::from_utf8(formatted.stdout)?.trim().to_string())
}

fn derive_recipient(account: &str) -> Result<String> {
    let output = Command::new("cast")
        .args(["wallet", "address", "--account", account])
        .output()
        .with_context(|| format!("`cast wallet address --account {account}`"))?;
    if !output.status.success() {
        bail!(
            "could not derive recipient from account '{account}'.\n\
             Set --recipient 0x... explicitly, or import a keystore via:\n  \
             cast wallet import {account} --interactive"
        );
    }
    Ok(String::from_utf8(output.stdout)?.trim().to_string())
}

fn check_docker() -> Result<()> {
    let status = Command::new("docker")
        .args(["info"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();
    match status {
        Ok(s) if s.success() => Ok(()),
        _ => bail!(
            "Docker is not running. Start Docker Desktop (needed for Groth16 wrap).\n\
             Or pass --dry-run for a score-only check that skips Groth16."
        ),
    }
}

// ────────────────────────────────────────────────────────────────────────────
// Eligibility

fn in_visited_range(visited: u64) -> bool {
    (MIN_VISITED..=MAX_VISITED).contains(&visited)
}

fn check_eligibility(visited: u64, tier: u8) {
    if !in_visited_range(visited) {
        eprintln!(
            "  ⚠ visited_cells = {visited} is outside [{MIN_VISITED}, {MAX_VISITED}] \
             — mint would revert with VisitedCellsOutOfRange."
        );
    }
    if tier == 0 {
        eprintln!("  ⚠ score < 10 → tier None — mint would revert with ScoreBelowFloor.");
    }
}

// ────────────────────────────────────────────────────────────────────────────
// Pretty printers

fn print_banner(cli: &Cli, recipient: &str, dry: bool) {
    let mode = if dry {
        "dry-run (score-only, no tx)"
    } else {
        "mint (real Base mainnet tx)"
    };
    eprintln!("════════════════════════════════════════════════════════════════");
    eprintln!("  windy-mine — {mode}");
    eprintln!("════════════════════════════════════════════════════════════════");
    eprintln!("  program:   {}", cli.program.display());
    eprintln!("  recipient: {recipient}");
    eprintln!("  account:   {}", cli.account);
    eprintln!("  minter:    {}", cli.minter);
    eprintln!("  rpc:       {}", cli.rpc);
    eprintln!(
        "  max_steps: {}, seed: {}{}",
        cli.max_steps,
        cli.seed,
        cli.nonce.as_deref().map(|n| format!(", nonce: {n}")).unwrap_or_default()
    );
    eprintln!("════════════════════════════════════════════════════════════════\n");
}

fn print_journal(journal: &WindyJournalSol, raw_len: usize) {
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
    println!("  visited_cells:      {}", journal.visitedCells);
    println!("  effective_cells:    {}", journal.effectiveCells);
    println!("  total_grid_cells:   {}", journal.totalGridCells);
    println!("  raw bytes:          {} (abi-encoded)", raw_len);
}

fn print_grade(score_x1000: u64, tier: u8) {
    let (name, reward) = match tier {
        0 => ("None", "0 (would revert with ScoreBelowFloor)"),
        1 => ("Bronze", "0.1 WNDY"),
        2 => ("Silver", "1.0 WNDY"),
        3 => ("Gold", "10.0 WNDY"),
        _ => ("?", "?"),
    };
    let int = score_x1000 / 1000;
    let frac = score_x1000 % 1000;
    eprintln!();
    eprintln!("════════════════════════════════════════════════════════════════");
    eprintln!("  Grade");
    eprintln!("════════════════════════════════════════════════════════════════");
    eprintln!("  score:    {int}.{frac:03}  (scoreX1000 = {score_x1000})");
    eprintln!("  tier:     {tier} → {name}");
    eprintln!("  reward:   {reward}");
    eprintln!("════════════════════════════════════════════════════════════════");
}

fn exit_label(code: i32) -> &'static str {
    match code {
        0 => "Ok",
        124 => "MaxSteps",
        134 => "Trap",
        _ => "Unknown",
    }
}

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

// ────────────────────────────────────────────────────────────────────────────
// Parsers

fn parse_address(s: &str) -> Result<[u8; 20]> {
    let s = s.strip_prefix("0x").unwrap_or(s);
    let bytes = hex::decode(s).context("address must be hex")?;
    if bytes.len() != 20 {
        bail!("address must be 20 bytes (40 hex chars), got {}", bytes.len());
    }
    let mut arr = [0u8; 20];
    arr.copy_from_slice(&bytes);
    Ok(arr)
}

fn parse_b256(s: &str) -> Result<[u8; 32]> {
    let s = s.strip_prefix("0x").unwrap_or(s);
    let bytes = hex::decode(s).context("nonce must be hex")?;
    if bytes.len() != 32 {
        bail!("nonce must be 32 bytes (64 hex chars), got {}", bytes.len());
    }
    let mut arr = [0u8; 32];
    arr.copy_from_slice(&bytes);
    Ok(arr)
}
