// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @notice Slim IShieldV2 surface that flash shields (T-30a) actually expose.
interface ISlimShield {
    function createPolicy(uint256 policyId, address holder, uint256 coverage, uint64 startTimestamp, uint64 expiresAt)
        external;
    function verifyAndCalculate(uint256 policyId)
        external
        returns (bool triggered, uint256 payout, address holder, bytes32 reason);
    function getPolicyInfo(uint256 policyId)
        external
        view
        returns (
            address holder,
            uint256 coverage,
            uint256 strikePrice,
            uint64 startTimestamp,
            uint64 expiresAt,
            bool finalized
        );
}

/// @title FlashShieldAdapter
/// @notice Sprint T-30b bridge: makes a slim T-30a flash shield speak the legacy
///         IShieldV2 surface that PolicyManagerV2 still expects (struct-based
///         createPolicy + PayoutResult return on verifyAndCalculate).
/// @dev    One adapter instance per slim shield. PolicyManagerV2 registers the
///         adapter (not the shield) for a given productId. The adapter assigns
///         policyIds with its own counter and forwards into the slim shield.
///         The shield trusts only the adapter (constructor `router` arg) — same
///         single-caller invariant as the production setup pre-adapter.
contract FlashShieldAdapter is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    ISlimShield public shield;
    bytes32 public productIdLocal;
    uint256 public nextPolicyId;

    struct LegacyCreatePolicyParams {
        address buyer;
        uint256 coverageAmount;
        uint256 premiumAmount;
        uint32 durationSeconds;
        bytes32 asset;
        bytes32 stablecoin;
        address protocol;
        bytes extraData;
    }

    struct LegacyPayoutResult {
        bool triggered;
        uint256 payoutAmount;
        address recipient;
        bytes32 reason;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _shield, bytes32 _productId) public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        require(_shield != address(0), "Zero shield");
        shield = ISlimShield(_shield);
        productIdLocal = _productId;
        nextPolicyId = 1;
    }

    function productId() external view returns (bytes32) {
        return productIdLocal;
    }

    /// @notice Forward legacy createPolicy into slim shield with adapter-assigned id.
    function createPolicy(LegacyCreatePolicyParams calldata params) external returns (uint256 policyId) {
        policyId = nextPolicyId++;
        uint64 startTs = uint64(block.timestamp);
        uint64 expiresAt = uint64(block.timestamp + params.durationSeconds);
        shield.createPolicy(policyId, params.buyer, params.coverageAmount, startTs, expiresAt);
    }

    /// @notice Forward legacy verifyAndCalculate to slim shield; oracleProof unused
    ///         (slim shields read Chainlink directly).
    function verifyAndCalculate(
        uint256 policyId,
        bytes calldata /*oracleProof*/
    )
        external
        returns (LegacyPayoutResult memory r)
    {
        (bool triggered, uint256 payout, address holder, bytes32 reason) = shield.verifyAndCalculate(policyId);
        r = LegacyPayoutResult({triggered: triggered, payoutAmount: payout, recipient: holder, reason: reason});
    }

    /// @notice Forward legacy getPolicyInfo signature (uint8 status) onto slim
    ///         shield's (bool finalized). Status mapping: 0 = active, 2 = finalized.
    function getPolicyInfo(uint256 policyId)
        external
        view
        returns (
            address insuredAgent,
            uint256 coverageAmount,
            uint256 premiumPaid,
            uint256 maxPayout,
            uint256 expiresAt,
            uint8 status
        )
    {
        (address holder, uint256 coverage,,, uint64 end, bool finalized) = shield.getPolicyInfo(policyId);
        insuredAgent = holder;
        coverageAmount = coverage;
        premiumPaid = 0; // slim shields don't track premium; PolicyManagerV2 already has it
        maxPayout = (coverage * 8000) / 10_000;
        expiresAt = uint256(end);
        status = finalized ? 2 : 0;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    uint256[47] private __gap;
}
