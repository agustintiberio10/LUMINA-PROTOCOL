// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IOracle} from "./IOracle.sol";

/**
 * @title IOracleV2
 * @author Lumina Protocol
 * @notice Extension interface for oracles that support EIP-712 domain-separated
 *         proof verification. V2 shields cast their bound oracle to this
 *         interface to call the new verifiers; V1 oracles do not implement
 *         these methods and would revert if cast.
 *
 * @dev    The EIP-712 domain pins each proof to (chainId, verifyingContract),
 *         preventing cross-chain and cross-contract replay. The domain
 *         separator is fixed at construction and exposed via DOMAIN_SEPARATOR().
 */
interface IOracleV2 is IOracle {
    /**
     * @notice Verify an EIP-712 typed PriceProof signature.
     * @dev    typehash: keccak256("PriceProof(int256 price,bytes32 asset,uint256 verifiedAt)")
     *         Returns the recovered signer (or address(0) on any failure).
     */
    function verifyPriceProofEIP712(
        int256 price,
        bytes32 asset,
        uint256 verifiedAt,
        bytes calldata signature
    ) external view returns (address signer);

    /**
     * @notice Verify an EIP-712 typed ExploitGovProof signature.
     * @dev    typehash: keccak256("ExploitGovProof(int256 govTokenPrice,int256 govTokenPrice24hAgo,bytes32 protocolId,uint256 verifiedAt)")
     *         Used by ExploitShield V2 for the gov-token-drop condition.
     */
    function verifyExploitGovProofEIP712(
        int256 govTokenPrice,
        int256 govTokenPrice24hAgo,
        bytes32 protocolId,
        uint256 verifiedAt,
        bytes calldata signature
    ) external view returns (address signer);

    /// @notice On-chain helper: build the EIP-712 digest for a PriceProof.
    function priceProofDigest(
        int256 price,
        bytes32 asset,
        uint256 verifiedAt
    ) external view returns (bytes32);

    /**
     * @notice On-chain helper: EIP-712 digest for the ExploitShield receipt-state
     *         attestation (consumed by the PhalaVerifier).
     * @dev    typehash: keccak256("ExploitReceiptProof(bool receiptTokenDepegged,bool contractPaused,bytes32 protocolId,uint256 verifiedAt)")
     */
    function exploitReceiptProofDigest(
        bool receiptTokenDepegged,
        bool contractPaused,
        bytes32 protocolId,
        uint256 verifiedAt
    ) external view returns (bytes32);

    /// @notice The EIP-712 domain separator (immutable, set at construction).
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}
