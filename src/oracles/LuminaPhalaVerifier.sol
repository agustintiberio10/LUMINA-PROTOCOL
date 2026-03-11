// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {IPhalaVerifier} from "../interfaces/IPhalaVerifier.sol";

/**
 * @title LuminaPhalaVerifier
 * @author Lumina Protocol
 * @notice Verifies attestations produced by Phala TEE workers.
 *
 * USED BY: ExploitShield (Condition 2 of the dual trigger).
 *
 * HOW IT WORKS:
 *   1. A Phala TEE worker monitors receipt token exchange rates every hour.
 *   2. If a depeg >30% persists for 4+ consecutive hours, or the contract
 *      is paused (read reverts), the worker produces an attestation.
 *   3. The attestation is an ECDSA signature over the data hash:
 *      keccak256(abi.encode(receiptTokenDepegged, contractPaused, protocolId, verifiedAt))
 *   4. On-chain: recover signer from (dataHash, attestation), check it's an authorized worker.
 *
 * SECURITY MODEL:
 *   - Phala TEE ensures the worker code is tamper-proof (runs in SGX/TDX enclave).
 *   - The worker's signing key is generated INSIDE the enclave and never leaves.
 *   - Multiple workers can be authorized for redundancy (different enclaves/nodes).
 *   - If a worker is compromised, admin removes it without affecting others.
 *   - Worker key rotation: add new → remove old (no downtime).
 *
 * TRUST ASSUMPTIONS:
 *   - Phala TEE hardware is not backdoored (standard Intel SGX assumption).
 *   - The worker code running in the enclave is audited and pinned to a hash.
 *   - Admin (owner) is a multisig that acts honestly on key management.
 *
 * @dev Ownable. NOT upgradeable — deploy new if needed, update ExploitShield
 *      (ExploitShield has immutable phalaVerifier — must redeploy Shield too).
 */
contract LuminaPhalaVerifier is IPhalaVerifier, Ownable {
    using ECDSA for bytes32;

    // ═══════════════════════════════════════════════════════════
    //  STORAGE
    // ═══════════════════════════════════════════════════════════

    /// @notice Set of authorized Phala worker public keys
    mapping(address => bool) private _authorizedWorkers;

    /// @notice List of all worker addresses (for enumeration)
    /// @dev Soft-delete: removeWorker sets authorized=false but does NOT remove from list.
    ///      Callers of getAllWorkers() must check isWorkerAuthorized() for each entry.
    address[] private _workerList;

    /// @notice Count of currently active workers
    uint256 private _activeWorkerCount;

    // ═══════════════════════════════════════════════════════════
    //  EVENTS
    // ═══════════════════════════════════════════════════════════

    event WorkerAdded(address indexed worker);
    event WorkerRemoved(address indexed worker);

    // ═══════════════════════════════════════════════════════════
    //  ERRORS
    // ═══════════════════════════════════════════════════════════

    error ZeroAddress(string param);
    error WorkerAlreadyAuthorized(address worker);
    error WorkerNotAuthorized(address worker);

    // ═══════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════

    /**
     * @param owner_ Admin address (multisig recommended)
     * @param initialWorker_ First Phala worker key (from TEE enclave)
     */
    constructor(address owner_, address initialWorker_) Ownable(owner_) {
        if (initialWorker_ == address(0)) revert ZeroAddress("initialWorker");
        _authorizedWorkers[initialWorker_] = true;
        _workerList.push(initialWorker_);
        _activeWorkerCount = 1;
        emit WorkerAdded(initialWorker_);
    }

    // ═══════════════════════════════════════════════════════════
    //  IPhalaVerifier — ATTESTATION VERIFICATION
    // ═══════════════════════════════════════════════════════════

    /// @inheritdoc IPhalaVerifier
    function verifyAttestation(
        bytes32 dataHash,
        bytes calldata attestation
    ) external view returns (bool valid) {
        // Attestation must be a 65-byte ECDSA signature
        if (attestation.length != 65) return false;

        // Recover signer
        (address recovered, ECDSA.RecoverError err, ) = ECDSA.tryRecover(dataHash, attestation);

        if (err != ECDSA.RecoverError.NoError) return false;

        // Check if signer is an authorized Phala worker
        return _authorizedWorkers[recovered];
    }

    // ═══════════════════════════════════════════════════════════
    //  ADMIN — WORKER KEY MANAGEMENT
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Authorize a new Phala worker key
     * @dev The worker key is the public key corresponding to the ECDSA key
     *      generated inside the Phala TEE enclave. Admin must verify the
     *      remote attestation report off-chain before calling this.
     *
     * @param worker Address derived from the worker's enclave signing key
     */
    function addWorker(address worker) external onlyOwner {
        if (worker == address(0)) revert ZeroAddress("worker");
        if (_authorizedWorkers[worker]) revert WorkerAlreadyAuthorized(worker);

        _authorizedWorkers[worker] = true;
        _workerList.push(worker);
        _activeWorkerCount++;

        emit WorkerAdded(worker);
    }

    /**
     * @notice Revoke a Phala worker key
     * @dev Call this when:
     *   - Worker enclave is compromised
     *   - Worker hardware is decommissioned
     *   - Planned key rotation (add new first, then remove old)
     *   - EMERGENCY: All workers compromised → remove all → verifyAttestation
     *     returns false for everything → ExploitShield claims blocked until
     *     new trusted worker is added.
     *
     *   [FIX] Allows removing the LAST worker (emergency pause).
     *   When _activeWorkerCount == 0, verifyAttestation returns false for
     *   ALL attestations, effectively pausing ExploitShield claims.
     *
     * @param worker Worker address to revoke
     */
    function removeWorker(address worker) external onlyOwner {
        if (!_authorizedWorkers[worker]) revert WorkerNotAuthorized(worker);

        _authorizedWorkers[worker] = false;
        _activeWorkerCount--;

        emit WorkerRemoved(worker);
    }

    // ═══════════════════════════════════════════════════════════
    //  VIEWS
    // ═══════════════════════════════════════════════════════════

    /// @notice Check if an address is an authorized worker
    function isWorkerAuthorized(address worker) external view returns (bool) {
        return _authorizedWorkers[worker];
    }

    /// @notice Get count of active workers
    function activeWorkerCount() external view returns (uint256) {
        return _activeWorkerCount;
    }

    /// @notice Get all worker addresses (includes revoked workers — soft-delete).
    /// @dev Revoked workers stay in this array. Filter with isWorkerAuthorized().
    function getAllWorkers() external view returns (address[] memory) {
        return _workerList;
    }
}
