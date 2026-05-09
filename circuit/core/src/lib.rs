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

#[cfg(test)]
mod tests {
    use super::*;
    use alloc::vec;
    use alloy_primitives::{Address, B256};
    use alloy_sol_types::SolValue;

    fn sample_journal() -> WindyJournalSol {
        WindyJournalSol {
            recipient: Address::from([0x12u8; 20]),
            nonce: B256::from([0x34u8; 32]),
            programHash: B256::from([0x56u8; 32]),
            outputHash: B256::from([0x78u8; 32]),
            exitCode: 0,
            steps: 29,
        }
    }

    #[test]
    fn journal_abi_roundtrip_preserves_all_fields() {
        let original = sample_journal();
        let encoded = original.abi_encode();

        // Six 32-byte slots: address, bytes32, bytes32, bytes32, int32, uint64.
        // Each fits in a single ABI head slot, so total is 6 * 32 = 192 bytes.
        assert_eq!(encoded.len(), 192);

        let decoded = WindyJournalSol::abi_decode_validate(&encoded).unwrap();
        assert_eq!(decoded.recipient, original.recipient);
        assert_eq!(decoded.nonce, original.nonce);
        assert_eq!(decoded.programHash, original.programHash);
        assert_eq!(decoded.outputHash, original.outputHash);
        assert_eq!(decoded.exitCode, original.exitCode);
        assert_eq!(decoded.steps, original.steps);
    }

    #[test]
    fn journal_abi_decode_rejects_truncated_input() {
        let encoded = sample_journal().abi_encode();
        let truncated = &encoded[..encoded.len() - 1];
        assert!(WindyJournalSol::abi_decode_validate(truncated).is_err());
    }

    #[test]
    fn journal_negative_exit_code_survives_roundtrip() {
        // ExitCode::Trap from windy-lang maps to i32 = 134; verify a
        // negative-looking int32 path too just in case the field type
        // ever changes upstream.
        let mut j = sample_journal();
        j.exitCode = -1;
        let decoded = WindyJournalSol::abi_decode_validate(&j.abi_encode()).unwrap();
        assert_eq!(decoded.exitCode, -1);
    }

    #[test]
    fn input_serde_roundtrip_preserves_all_fields() {
        // WindyInput uses risc0 serde (postcard), not ABI. We just verify
        // the standard serde round-trip through bincode (a stand-in)
        // preserves all six fields.
        let original = WindyInput {
            program: alloc::string::ToString::to_string("\"hi\",,@"),
            seed: 42,
            max_steps: 100_000,
            stdin: vec![1, 2, 3],
            recipient: [0xAAu8; 20],
            nonce: [0xBBu8; 32],
        };

        let bytes = postcard::to_allocvec(&original).unwrap();
        let decoded: WindyInput = postcard::from_bytes(&bytes).unwrap();

        assert_eq!(decoded.program, original.program);
        assert_eq!(decoded.seed, original.seed);
        assert_eq!(decoded.max_steps, original.max_steps);
        assert_eq!(decoded.stdin, original.stdin);
        assert_eq!(decoded.recipient, original.recipient);
        assert_eq!(decoded.nonce, original.nonce);
    }
}
