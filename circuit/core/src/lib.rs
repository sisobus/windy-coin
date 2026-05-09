//! Shared types for the windy-coin Risc Zero circuit.
//!
//! - [`WindyInput`] is the host→guest payload, written via
//!   `ExecutorEnv::write` and read via `env::read`. Stays in risc0's
//!   serde format because no on-chain code reads it.
//! - [`WindyJournalSol`] is the guest→world payload, ABI-encoded and
//!   committed via `env::commit_slice`. Solidity (or any caller using
//!   `abi.decode`) can parse it directly. Phase 2 layout: 13 fields,
//!   416 ABI bytes.
//!
//! See [`docs/PHASE-2-MINING.md`](../../docs/PHASE-2-MINING.md) at the
//! workspace root for the policy that interprets these fields.

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
    /// `ZkExecutionMinterV2` can `abi.decode(journal, (WindyJournalSol))`.
    ///
    /// Field order is **load-bearing** — both the guest commit and the
    /// minter `abi.decode` rely on this exact sequence. Adding a field
    /// at the tail is the only forward-compatible mutation.
    ///
    /// Bit assignments for `hardOpcodeBitmap`, in order from LSB:
    ///
    /// | bit | opcode | meaning                                 |
    /// |-----|--------|-----------------------------------------|
    /// | 0   | `t`    | SPLIT — at least one IP spawn           |
    /// | 1   | `p`    | GRID_PUT — at least one self-write      |
    /// | 2   | `g`    | GRID_GET — at least one self-read       |
    /// | 3   | `_`    | IF_H — at least one horizontal branch   |
    /// | 4   | `\|`   | IF_V — at least one vertical branch     |
    /// | 5   | `≫`    | GUST — at least one speed bump          |
    /// | 6   | `≪`    | CALM — at least one speed cut           |
    /// | 7   | `~`    | TURBULENCE — at least one random turn   |
    /// | 8   | `#`    | TRAMPOLINE — at least one cell skip     |
    /// | 9   | `"`    | STR_MODE — at least one mode toggle     |
    ///
    /// Bits 10..15 are reserved.
    #[derive(Debug)]
    struct WindyJournalSol {
        // Phase 1 fields — unchanged so the off-chain bookkeeping that
        // tracks proofs across versions stays parseable.
        address recipient;
        bytes32 nonce;
        bytes32 programHash;
        bytes32 outputHash;
        int32   exitCode;
        uint64  steps;

        // Phase 2 additions — the inputs the mining-policy contract
        // grades the proof on.
        uint16  hardOpcodeBitmap;
        uint64  maxAliveIps;
        uint64  spawnedIps;
        uint64  gridWrites;
        uint64  branchCount;
        uint64  visitedCells;
        uint32  effectiveCells;
        uint32  totalGridCells;
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
            hardOpcodeBitmap: 0b00_0010_0001,
            maxAliveIps: 4,
            spawnedIps: 3,
            gridWrites: 7,
            branchCount: 2,
            visitedCells: 13,
            effectiveCells: 17,
            totalGridCells: 17,
        }
    }

    #[test]
    fn journal_v2_abi_roundtrip_preserves_all_fields() {
        let original = sample_journal();
        let encoded = original.abi_encode();

        // 14 head slots × 32 bytes = 448 bytes. Each field — even
        // uint16 / uint32 / uint64 — occupies a full 32-byte ABI word.
        assert_eq!(encoded.len(), 448);

        let decoded = WindyJournalSol::abi_decode_validate(&encoded).unwrap();
        assert_eq!(decoded.recipient, original.recipient);
        assert_eq!(decoded.nonce, original.nonce);
        assert_eq!(decoded.programHash, original.programHash);
        assert_eq!(decoded.outputHash, original.outputHash);
        assert_eq!(decoded.exitCode, original.exitCode);
        assert_eq!(decoded.steps, original.steps);
        assert_eq!(decoded.hardOpcodeBitmap, original.hardOpcodeBitmap);
        assert_eq!(decoded.maxAliveIps, original.maxAliveIps);
        assert_eq!(decoded.spawnedIps, original.spawnedIps);
        assert_eq!(decoded.gridWrites, original.gridWrites);
        assert_eq!(decoded.branchCount, original.branchCount);
        assert_eq!(decoded.visitedCells, original.visitedCells);
        assert_eq!(decoded.effectiveCells, original.effectiveCells);
        assert_eq!(decoded.totalGridCells, original.totalGridCells);
    }

    #[test]
    fn journal_v2_abi_decode_rejects_truncated_input() {
        let encoded = sample_journal().abi_encode();
        let truncated = &encoded[..encoded.len() - 1];
        assert!(WindyJournalSol::abi_decode_validate(truncated).is_err());
    }

    #[test]
    fn journal_v2_negative_exit_code_survives_roundtrip() {
        let mut j = sample_journal();
        j.exitCode = -1;
        let decoded = WindyJournalSol::abi_decode_validate(&j.abi_encode()).unwrap();
        assert_eq!(decoded.exitCode, -1);
    }

    #[test]
    fn journal_v2_max_metric_values_survive_roundtrip() {
        let mut j = sample_journal();
        j.steps = u64::MAX;
        j.maxAliveIps = u64::MAX;
        j.spawnedIps = u64::MAX;
        j.gridWrites = u64::MAX;
        j.branchCount = u64::MAX;
        j.visitedCells = u64::MAX;
        j.effectiveCells = u32::MAX;
        j.totalGridCells = u32::MAX;
        j.hardOpcodeBitmap = u16::MAX;
        let decoded = WindyJournalSol::abi_decode_validate(&j.abi_encode()).unwrap();
        assert_eq!(decoded.steps, u64::MAX);
        assert_eq!(decoded.maxAliveIps, u64::MAX);
        assert_eq!(decoded.spawnedIps, u64::MAX);
        assert_eq!(decoded.gridWrites, u64::MAX);
        assert_eq!(decoded.branchCount, u64::MAX);
        assert_eq!(decoded.visitedCells, u64::MAX);
        assert_eq!(decoded.effectiveCells, u32::MAX);
        assert_eq!(decoded.totalGridCells, u32::MAX);
        assert_eq!(decoded.hardOpcodeBitmap, u16::MAX);
    }

    #[test]
    fn input_serde_roundtrip_preserves_all_fields() {
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
