// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {IOracle} from "../interfaces/IOracle.sol";
import {IOracleV2} from "../interfaces/IOracleV2.sol";
import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";

/**
 * @title LuminaOracleV2
 * @author Lumina Protocol
 * @notice V2 of the Lumina oracle. Adds EIP-712 domain-separated proof
 *         verification on top of the V1 surface (which remains for backward
 *         compatibility with V1 shields).
 *
 * ─────────────────────────────────────────────────────────────────────────
 * V1 → V2 CHANGES
 * ─────────────────────────────────────────────────────────────────────────
 *
 * 1. EIP-712 DOMAIN SEPARATION (FIX HIGH-1 from oracle audit)
 *    Every claim proof now includes the chain id and verifying-contract
 *    address through an EIP-712 domain separator.  Concretely:
 *      - A proof signed against Base Sepolia (chainId 84532) cannot be
 *        replayed on Base mainnet (chainId 8453).
 *      - A proof signed for *this* oracle cannot be replayed against a
 *        different oracle deployment, even on the same chain.
 *      - Proofs are now standard EIP-712 typed-data — auditable and
 *        compatible with hardware wallets / signTypedData tooling.
 *
 * 2. HONEST DOCUMENTATION (FIX HIGH-2)
 *    The V1 NatSpec advertised "TWAP 15 min or 3 Chainlink rounds".
 *    The V1 contract did not implement that. V2 documents exactly what
 *    happens: Shields verify ONE oracle-signed Chainlink spot price, the
 *    relayer reads `latestRoundData` and signs the result. There is no
 *    on-chain TWAP. There is no SGX/TDX hardware attestation — the
 *    PhalaVerifier is an admin-curated EOA signer set.
 *
 * 3. CORRECT FEED ADDRESSES IN NATSPEC
 *    The V1 NatSpec listed `BTC/USD: 0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F`.
 *    The actually-registered BTC feed on Base mainnet is
 *    `0xCCADC697c55bbB68dc5bCdf8d3CBe83CdD4E071E` (Chainlink Data Feed BTC/USD on Base).
 *    V2 documents the canonical Base mainnet addresses.
 *
 * 4. UPGRADEABILITY POLICY
 *    LuminaOracleV2 is **NOT upgradeable**. To replace it: deploy V3,
 *    call `CoverRouter.setOracle(newOracle)`, AND redeploy every Shield
 *    that depends on it (Shield.oracle is `immutable`). Document this
 *    every place "UUPS" appears in user-facing prose.
 *
 * ─────────────────────────────────────────────────────────────────────────
 * BACKWARD COMPATIBILITY
 * ─────────────────────────────────────────────────────────────────────────
 *
 * The V1 functions `verifySignature(digest, sig)` and the multisig packed
 * variant remain available unchanged. V1 shields keep working when paired
 * with this oracle. The V2 functions are additive:
 *   - verifyPriceProofEIP712()
 *   - verifyExploitGovProofEIP712()
 *   - priceProofDigest() / exploitReceiptProofDigest()  (view helpers)
 *
 * ─────────────────────────────────────────────────────────────────────────
 * CHAINLINK FEEDS ON BASE MAINNET (chainId 8453)
 * ─────────────────────────────────────────────────────────────────────────
 *
 *   ETH/USD:  0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70   (heartbeat 1200s)
 *   BTC/USD:  0xCCADC697c55bbB68dc5bCdf8d3CBe83CdD4E071E   (heartbeat 1200s)
 *   USDC/USD: 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B   (heartbeat 86400s)
 *   USDT/USD: 0xf19d560eB8d2ADf07BD6D13ed03e1D11215721F9   (heartbeat 86400s)
 *   DAI/USD:  0x591e79239a7d679378eC8c847e5038150364C78F   (heartbeat 86400s)
 *
 *   Sequencer Uptime Feed: 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433
 */
contract LuminaOracleV2 is IOracleV2, Ownable {
    using ECDSA for bytes32;

    // ═══════════════════════════════════════════════════════════
    //  CONSTANTS
    // ═══════════════════════════════════════════════════════════

    /// @notice Grace period after sequencer restarts before accepting prices.
    uint256 public constant SEQUENCER_GRACE_PERIOD = 1 hours;

    /// @notice Conservative downtime extension floor (matches V1).
    uint256 public constant MIN_DOWNTIME_EXTENSION = 2 hours;

    // ── EIP-712 typehashes ────────────────────────────────────────────────

    bytes32 public constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    /// @dev keccak256("PriceProof(int256 price,bytes32 asset,uint256 verifiedAt)")
    bytes32 public constant PRICE_PROOF_TYPEHASH = keccak256(
        "PriceProof(int256 price,bytes32 asset,uint256 verifiedAt)"
    );

    /// @dev keccak256("ExploitGovProof(int256 govTokenPrice,int256 govTokenPrice24hAgo,bytes32 protocolId,uint256 verifiedAt)")
    bytes32 public constant EXPLOIT_GOV_PROOF_TYPEHASH = keccak256(
        "ExploitGovProof(int256 govTokenPrice,int256 govTokenPrice24hAgo,bytes32 protocolId,uint256 verifiedAt)"
    );

    /// @dev keccak256("ExploitReceiptProof(bool receiptTokenDepegged,bool contractPaused,bytes32 protocolId,uint256 verifiedAt)")
    bytes32 public constant EXPLOIT_RECEIPT_PROOF_TYPEHASH = keccak256(
        "ExploitReceiptProof(bool receiptTokenDepegged,bool contractPaused,bytes32 protocolId,uint256 verifiedAt)"
    );

    // ═══════════════════════════════════════════════════════════
    //  STRUCTS
    // ═══════════════════════════════════════════════════════════

    struct FeedConfig {
        IAggregatorV3 feed;
        uint256 maxStaleness;
        bool active;
    }

    // ═══════════════════════════════════════════════════════════
    //  STORAGE
    // ═══════════════════════════════════════════════════════════

    address private _oracleKey;
    mapping(bytes32 => FeedConfig) private _feeds;
    bytes32[] private _assetIds;
    IAggregatorV3 private immutable _sequencerUptimeFeed;

    // ── Multisig oracle (V1-compatible) ──
    mapping(address => bool) public authorizedSigners;
    uint256 public requiredSignatures;
    uint256 public totalSigners;

    // ── EIP-712 domain separator ──
    /// @notice Cached at construction. Pinned to (chainId, address(this)).
    bytes32 public immutable DOMAIN_SEPARATOR;

    // ═══════════════════════════════════════════════════════════
    //  EVENTS
    // ═══════════════════════════════════════════════════════════

    event OracleKeyRotated(address indexed oldKey, address indexed newKey);
    event FeedRegistered(bytes32 indexed asset, address indexed feed, uint256 maxStaleness);
    event FeedUpdated(bytes32 indexed asset, address indexed feed, uint256 maxStaleness);
    event FeedRemoved(bytes32 indexed asset);
    event SignerAdded(address indexed signer);
    event SignerRemoved(address indexed signer);
    event QuorumChanged(uint256 required);

    // ═══════════════════════════════════════════════════════════
    //  ERRORS
    // ═══════════════════════════════════════════════════════════

    error ZeroAddress(string param);
    error ZeroValue(string param);
    error FeedNotRegistered(bytes32 asset);
    error FeedAlreadyRegistered(bytes32 asset);
    error StalePriceAsset(bytes32 asset, uint256 updatedAt, uint256 maxStaleness);
    error InvalidPriceAsset(bytes32 asset, int256 price);
    error IncompleteRound(bytes32 asset, uint80 roundId, uint80 answeredInRound);
    error InvalidSignatureLength();
    error SequencerDown();
    error SequencerGracePeriodNotOver();

    // ═══════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════

    constructor(
        address owner_,
        address oracleKey_,
        address sequencerUptimeFeed_
    ) Ownable(owner_) {
        if (oracleKey_ == address(0)) revert ZeroAddress("oracleKey");
        _oracleKey = oracleKey_;
        _sequencerUptimeFeed = IAggregatorV3(sequencerUptimeFeed_);
        emit OracleKeyRotated(address(0), oracleKey_);

        authorizedSigners[oracleKey_] = true;
        totalSigners = 1;
        requiredSignatures = 1;

        // EIP-712 domain separator: pinned to deployment chain + this contract.
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("LuminaOracle")),
                keccak256(bytes("2")),
                block.chainid,
                address(this)
            )
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  IOracle — SPOT PRICE READS (unchanged from V1)
    // ═══════════════════════════════════════════════════════════

    function getLatestPrice(bytes32 asset) external view returns (int256 price) {
        _checkSequencer();

        FeedConfig storage config = _feeds[asset];
        if (!config.active) revert FeedNotRegistered(asset);

        (
            uint80 roundId,
            int256 answer,
            /* startedAt */,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = config.feed.latestRoundData();

        if (answer <= 0) revert InvalidPriceAsset(asset, answer);
        if (answeredInRound < roundId) revert IncompleteRound(asset, roundId, answeredInRound);
        if (updatedAt > block.timestamp || block.timestamp - updatedAt > config.maxStaleness) {
            revert StalePriceAsset(asset, updatedAt, config.maxStaleness);
        }

        price = answer;
    }

    // ═══════════════════════════════════════════════════════════
    //  IOracle — V1 SIGNATURE VERIFICATION (kept for compatibility)
    // ═══════════════════════════════════════════════════════════

    function verifySignature(
        bytes32 digest,
        bytes calldata signature
    ) external view returns (address signer) {
        if (requiredSignatures > 1) {
            if (verifyPackedMultisig(digest, signature)) return _oracleKey;
            return address(0);
        }

        if (signature.length != 65) revert InvalidSignatureLength();

        (address recovered, ECDSA.RecoverError err, ) = ECDSA.tryRecover(digest, signature);
        if (err != ECDSA.RecoverError.NoError) return address(0);

        if (authorizedSigners[recovered] || recovered == _oracleKey) return recovered;
        return address(0);
    }

    function verifyPackedMultisig(
        bytes32 dataHash,
        bytes calldata packedSignatures
    ) public view returns (bool) {
        uint256 sigCount = packedSignatures.length / 65;
        require(sigCount >= requiredSignatures, "Not enough signatures");
        require(packedSignatures.length % 65 == 0, "Invalid signature length");

        address lastSigner = address(0);
        for (uint256 i = 0; i < sigCount; i++) {
            bytes calldata sig = packedSignatures[i * 65:(i + 1) * 65];
            address recovered = ECDSA.recover(dataHash, sig);
            require(authorizedSigners[recovered], "Unauthorized signer");
            require(uint160(recovered) > uint160(lastSigner), "Signatures not ordered or duplicate");
            lastSigner = recovered;
        }
        return true;
    }

    function oracleKey() external view returns (address) {
        return _oracleKey;
    }

    // ═══════════════════════════════════════════════════════════
    //  V2 — EIP-712 DOMAIN-SEPARATED PROOF VERIFICATION
    // ═══════════════════════════════════════════════════════════

    /// @inheritdoc IOracleV2
    function verifyPriceProofEIP712(
        int256 price,
        bytes32 asset,
        uint256 verifiedAt,
        bytes calldata signature
    ) external view returns (address signer) {
        bytes32 digest = priceProofDigest(price, asset, verifiedAt);
        return _verifyEip712(digest, signature);
    }

    /// @inheritdoc IOracleV2
    function verifyExploitGovProofEIP712(
        int256 govTokenPrice,
        int256 govTokenPrice24hAgo,
        bytes32 protocolId,
        uint256 verifiedAt,
        bytes calldata signature
    ) external view returns (address signer) {
        bytes32 structHash = keccak256(
            abi.encode(
                EXPLOIT_GOV_PROOF_TYPEHASH,
                govTokenPrice,
                govTokenPrice24hAgo,
                protocolId,
                verifiedAt
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        return _verifyEip712(digest, signature);
    }

    /// @inheritdoc IOracleV2
    function priceProofDigest(
        int256 price,
        bytes32 asset,
        uint256 verifiedAt
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(PRICE_PROOF_TYPEHASH, price, asset, verifiedAt)
        );
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }

    /// @inheritdoc IOracleV2
    function exploitReceiptProofDigest(
        bool receiptTokenDepegged,
        bool contractPaused,
        bytes32 protocolId,
        uint256 verifiedAt
    ) external view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                EXPLOIT_RECEIPT_PROOF_TYPEHASH,
                receiptTokenDepegged,
                contractPaused,
                protocolId,
                verifiedAt
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }

    /// @dev Shared EIP-712 verification path: validates packed multisig OR
    ///      single ECDSA against authorizedSigners + canonical oracleKey.
    function _verifyEip712(bytes32 digest, bytes calldata signature) internal view returns (address signer) {
        if (requiredSignatures > 1) {
            if (verifyPackedMultisig(digest, signature)) return _oracleKey;
            return address(0);
        }

        if (signature.length != 65) revert InvalidSignatureLength();

        (address recovered, ECDSA.RecoverError err, ) = ECDSA.tryRecover(digest, signature);
        if (err != ECDSA.RecoverError.NoError) return address(0);

        if (authorizedSigners[recovered] || recovered == _oracleKey) return recovered;
        return address(0);
    }

    // ═══════════════════════════════════════════════════════════
    //  ADMIN — ORACLE KEY MANAGEMENT
    // ═══════════════════════════════════════════════════════════

    function setOracleKey(address newKey) external onlyOwner {
        if (newKey == address(0)) revert ZeroAddress("oracleKey");
        address oldKey = _oracleKey;
        _oracleKey = newKey;
        emit OracleKeyRotated(oldKey, newKey);
    }

    function addSigner(address signer_) external onlyOwner {
        require(signer_ != address(0), "Zero address");
        require(!authorizedSigners[signer_], "Already a signer");
        authorizedSigners[signer_] = true;
        totalSigners++;
        emit SignerAdded(signer_);
    }

    function removeSigner(address signer_) external onlyOwner {
        require(authorizedSigners[signer_], "Not a signer");
        require(totalSigners - 1 >= requiredSignatures, "Would break quorum");
        authorizedSigners[signer_] = false;
        totalSigners--;
        emit SignerRemoved(signer_);
    }

    function setRequiredSignatures(uint256 _required) external onlyOwner {
        require(_required > 0, "Must be > 0");
        require(_required <= totalSigners, "Exceeds total signers");
        requiredSignatures = _required;
        emit QuorumChanged(_required);
    }

    function getSignerInfo() external view returns (uint256 _required, uint256 _total) {
        return (requiredSignatures, totalSigners);
    }

    function isSigner(address addr_) external view returns (bool) {
        return authorizedSigners[addr_];
    }

    // ═══════════════════════════════════════════════════════════
    //  ADMIN — FEED MANAGEMENT
    // ═══════════════════════════════════════════════════════════

    function registerFeed(bytes32 asset, address feed, uint256 maxStaleness) external onlyOwner {
        if (feed == address(0)) revert ZeroAddress("feed");
        if (_feeds[asset].active) revert FeedAlreadyRegistered(asset);
        if (maxStaleness == 0) revert ZeroValue("maxStaleness");

        IAggregatorV3 aggregator = IAggregatorV3(feed);
        (, int256 testPrice, , , ) = aggregator.latestRoundData();
        if (testPrice <= 0) revert InvalidPriceAsset(asset, testPrice);

        _feeds[asset] = FeedConfig({feed: aggregator, maxStaleness: maxStaleness, active: true});
        _assetIds.push(asset);
        emit FeedRegistered(asset, feed, maxStaleness);
    }

    function updateFeed(bytes32 asset, address feed, uint256 maxStaleness) external onlyOwner {
        if (!_feeds[asset].active) revert FeedNotRegistered(asset);
        if (feed == address(0)) revert ZeroAddress("feed");
        if (maxStaleness == 0) revert ZeroValue("maxStaleness");

        IAggregatorV3 aggregator = IAggregatorV3(feed);
        (, int256 testPrice, , , ) = aggregator.latestRoundData();
        if (testPrice <= 0) revert InvalidPriceAsset(asset, testPrice);

        _feeds[asset].feed = aggregator;
        _feeds[asset].maxStaleness = maxStaleness;
        emit FeedUpdated(asset, feed, maxStaleness);
    }

    function removeFeed(bytes32 asset) external onlyOwner {
        if (!_feeds[asset].active) revert FeedNotRegistered(asset);
        _feeds[asset].active = false;
        emit FeedRemoved(asset);
    }

    // ═══════════════════════════════════════════════════════════
    //  VIEWS
    // ═══════════════════════════════════════════════════════════

    function getFeedConfig(bytes32 asset)
        external
        view
        returns (address feed, uint256 maxStaleness, bool active)
    {
        FeedConfig storage config = _feeds[asset];
        return (address(config.feed), config.maxStaleness, config.active);
    }

    function getAllAssets() external view returns (bytes32[] memory) {
        return _assetIds;
    }

    function isFeedActive(bytes32 asset) external view returns (bool) {
        return _feeds[asset].active;
    }

    function getLatestRoundData(bytes32 asset)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        _checkSequencer();
        FeedConfig storage config = _feeds[asset];
        if (!config.active) revert FeedNotRegistered(asset);

        (roundId, answer, startedAt, updatedAt, answeredInRound) = config.feed.latestRoundData();
        if (answer <= 0) revert InvalidPriceAsset(asset, answer);
        if (answeredInRound < roundId) revert IncompleteRound(asset, roundId, answeredInRound);
        if (updatedAt > block.timestamp || block.timestamp - updatedAt > config.maxStaleness) {
            revert StalePriceAsset(asset, updatedAt, config.maxStaleness);
        }
    }

    function sequencerUptimeFeed() external view returns (address) {
        return address(_sequencerUptimeFeed);
    }

    function getSequencerDowntime(uint256 sinceTimestamp) external view returns (uint256 downtime) {
        if (address(_sequencerUptimeFeed) == address(0)) return 0;

        try _sequencerUptimeFeed.latestRoundData() returns (
            uint80, int256 status, uint256 startedAt, uint256, uint80
        ) {
            if (status != 0) {
                if (block.timestamp > sinceTimestamp) return block.timestamp - sinceTimestamp;
                return MIN_DOWNTIME_EXTENSION;
            }
            if (startedAt > sinceTimestamp) {
                uint256 detected = startedAt - sinceTimestamp;
                return detected > MIN_DOWNTIME_EXTENSION ? detected : MIN_DOWNTIME_EXTENSION;
            }
            return 0;
        } catch {
            return 0;
        }
    }

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL — L2 SEQUENCER CHECK
    // ═══════════════════════════════════════════════════════════

    function _checkSequencer() internal view {
        if (address(_sequencerUptimeFeed) == address(0)) return;

        (
            /* uint80 roundId */,
            int256 status,
            uint256 startedAt,
            /* uint256 updatedAt */,
            /* uint80 answeredInRound */
        ) = _sequencerUptimeFeed.latestRoundData();

        if (status != 0) revert SequencerDown();

        if (block.timestamp - startedAt <= SEQUENCER_GRACE_PERIOD) {
            revert SequencerGracePeriodNotOver();
        }
    }
}
