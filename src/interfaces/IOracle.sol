// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IOracle
 * @author Lumina Protocol
 * @notice Interface for Lumina's oracle implementation.
 *
 * DESIGN:
 *   - getLatestPrice(): spot read from Chainlink feed (for policy creation)
 *   - verifySignature(): ECDSA signature verification (for claims + EIP-712 quotes)
 *   - oracleKey(): authorized signing key
 *
 * PRODUCTS THAT USE IT:
 *   - BSS: getLatestPrice("ETH"/"BTC") at policy creation
 *   - IL Index: getLatestPrice("ETH") at policy creation
 *   - All Shields: verifySignature() for oracle-signed TWAP proofs at claim time
 */
interface IOracle {

    // ═══════════════════════════════════════════════════════════
    //  PRICE READING
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Read the latest price for an asset from its registered Chainlink feed
     * @param asset Asset identifier (e.g., "ETH", "BTC", "USDC")
     * @return price Price in Chainlink 8-decimal format
     */
    function getLatestPrice(bytes32 asset) external view returns (int256 price);

    // ═══════════════════════════════════════════════════════════
    //  SIGNATURE VERIFICATION
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Verify an ECDSA signature and return the recovered signer
     * @param digest Hash that was signed
     * @param signature 65-byte ECDSA signature (r, s, v)
     * @return signer Recovered signer address
     */
    function verifySignature(
        bytes32 digest,
        bytes calldata signature
    ) external view returns (address signer);

    /**
     * @notice Return the authorized oracle signing key
     * @return key Address of the oracle key
     */
    function oracleKey() external view returns (address key);
}
