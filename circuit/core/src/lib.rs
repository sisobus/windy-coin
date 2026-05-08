//! Shared types for the windy-coin Risc Zero circuit.
//!
//! `WindyInput` is what the host writes into `ExecutorEnv` and the
//! guest reads via `env::read`. `WindyJournal` is what the guest
//! commits to the receipt journal — public output that both the host
//! and an on-chain verifier read.

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
}

#[derive(Serialize, Deserialize)]
pub struct WindyJournal {
    pub program_hash: [u8; 32],
    pub output_hash: [u8; 32],
    pub exit_code: i32,
    pub steps: u64,
}
