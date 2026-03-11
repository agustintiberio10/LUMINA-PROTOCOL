// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IPhalaVerifier
 * @author Lumina Protocol
 * @notice Interface for Phala TEE attestation verification.
 *         Used by ExploitShield (Condition 2 of the dual trigger).
 *
 * HOW IT WORKS:
 *   1. A Phala TEE worker monitors receipt token exchange rates.
 *   2. If depeg >30% persists 4+ hours (or contract paused), worker signs attestation.
 *   3. On-chain: verifyAttestation recovers signer, checks it's an authorized worker.
 */
interface IPhalaVerifier {

    /**
     * @notice Verify an attestation was produced by an authorized Phala TEE worker
     * @param dataHash keccak256 of the encoded attestation data
     * @param attestation 65-byte ECDSA signature from the TEE worker
     * @return valid True if signature is from an authorized worker
     */
    function verifyAttestation(
        bytes32 dataHash,
        bytes calldata attestation
    ) external view returns (bool valid);
}
