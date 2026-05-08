//! Shared types for the windy-coin Risc Zero circuit.
//!
//! - `WindyInput` is the host→guest payload, written via
//!   `ExecutorEnv::write` and read via `env::read`. Stays in risc0's
//!   serde format because no on-chain code reads it.
//! - `WindyJournalSol` is the guest→world payload, ABI-encoded and
//!   committed via `env::commit_slice`. Solidity (or any caller using
//!   `abi.decode`) can parse it directly.

#![no_std]

extern crate alloc;

use alloc::string::String;
use alloc::vec::Vec;
use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize)]
pub struct WindyInput {
    pub program: String,
    pub seed: u64,
    pub max_steps: u64,
    pub stdin: Vec<u8>,
    pub recipient: [u8; 20],
    pub nonce: [u8; 32],
}

alloy_sol_types::sol! {
    /// Public output committed by the guest. The ABI-encoded bytes of
    /// this struct are exactly what `receipt.journal.bytes` contains, so
    /// `ZkExecutionMinter` can do `abi.decode(journal, (WindyJournalSol))`.
    #[derive(Debug)]
    struct WindyJournalSol {
        address recipient;
        bytes32 nonce;
        bytes32 programHash;
        bytes32 outputHash;
        int32 exitCode;
        uint64 steps;
    }
}
