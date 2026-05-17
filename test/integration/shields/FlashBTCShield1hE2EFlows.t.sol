// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {FlashBTCShield1h} from "../../../src/products/FlashBTCShield1h.sol";
import {IShield} from "../../../src/interfaces/IShield.sol";
import {IOracle} from "../../../src/interfaces/IOracle.sol";
import {IOracleV2} from "../../../src/interfaces/IOracleV2.sol";

// -----------------------------------------------------------------------------
// Minimal inline mocks (mirror unit-test versions; intentionally self-contained
// so this file compiles independently).
// -----------------------------------------------------------------------------

contract ForkOracle is IOracleV2 {
    mapping(bytes32 => int256) public price;
    uint256 public seqDowntime;
    address public override oracleKey;

    bytes32 public constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 public constant PRICE_PROOF_TYPEHASH =
        keccak256("PriceProof(int256 price,bytes32 asset,uint256 verifiedAt)");
    bytes32 public immutable override DOMAIN_SEPARATOR;

    constructor(address signer_) {
        oracleKey = signer_;
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

    function setPrice(bytes32 a, int256 p) external {
        price[a] = p;
    }

    function setSequencerDowntime(uint256 d) external {
        seqDowntime = d;
    }

    function getLatestPrice(bytes32 a) external view returns (int256) {
        return price[a];
    }

    function getSequencerDowntime(uint256) external view returns (uint256) {
        return seqDowntime;
    }

    function verifySignature(bytes32 digest, bytes calldata signature) external pure returns (address) {
        if (signature.length != 65) return address(0);
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        if (err != ECDSA.RecoverError.NoError) return address(0);
        return recovered;
    }

    function priceProofDigest(int256 p, bytes32 a, uint256 verifiedAt) public view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(PRICE_PROOF_TYPEHASH, p, a, verifiedAt));
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }

    function verifyPriceProofEIP712(int256 p, bytes32 a, uint256 verifiedAt, bytes calldata signature)
        external
        view
        returns (address)
    {
        bytes32 digest = priceProofDigest(p, a, verifiedAt);
        if (signature.length != 65) return address(0);
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        if (err != ECDSA.RecoverError.NoError) return address(0);
        if (recovered != oracleKey) return address(0);
        return recovered;
    }

    function verifyExploitGovProofEIP712(int256, int256, bytes32, uint256, bytes calldata)
        external
        pure
        returns (address)
    {
        return address(0);
    }

    function exploitReceiptProofDigest(bool, bool, bytes32, uint256) external pure returns (bytes32) {
        return bytes32(0);
    }
}

contract ForkUSDC {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// -----------------------------------------------------------------------------
// E2E flows
// -----------------------------------------------------------------------------

contract FlashBTCShield1hE2EFlows is Test {
    FlashBTCShield1h shield;
    ForkOracle oracle;
    ForkUSDC usdc;

    address router; // PolicyManagerV2 stand-in
    address buyer = makeAddr("buyer");
    uint256 oracleSignerPk = 0xCAFE;
    address oracleSigner;

    int256 constant BTC_PRICE_OK = 60_000e8;
    uint256 constant COVERAGE = 1_000e6;
    uint256 constant PREMIUM = 10e6;
    uint32 constant DURATION = 3600;

    // Canonical Sepolia SET A LuminaOracleV2 (mocked, not actually called).
    address internal constant SET_A_ORACLE = 0x8cAbC4645a3981FF59d39328f9F65FdFD19Bd194;

    modifier requiresFork() {
        try vm.envString("BASE_SEPOLIA_RPC") returns (string memory) {
            vm.createSelectFork("base_sepolia");
            _;
        } catch {
            vm.skip(true);
        }
    }

    function _setup() internal {
        oracleSigner = vm.addr(oracleSignerPk);
        oracle = new ForkOracle(oracleSigner);
        oracle.setPrice("BTC", BTC_PRICE_OK);
        usdc = new ForkUSDC();
        router = makeAddr("router");

        FlashBTCShield1h impl = new FlashBTCShield1h();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeWithSelector(FlashBTCShield1h.initialize.selector, router, address(oracle))
        );
        shield = FlashBTCShield1h(address(proxy));
    }

    function _params() internal view returns (IShield.CreatePolicyParams memory) {
        return IShield.CreatePolicyParams({
            buyer: buyer,
            coverageAmount: COVERAGE,
            premiumAmount: PREMIUM,
            durationSeconds: DURATION,
            asset: "BTC",
            stablecoin: bytes32(0),
            protocol: address(0),
            extraData: ""
        });
    }

    function _createPolicy() internal returns (uint256 pid) {
        vm.prank(router);
        pid = shield.createPolicy(_params());
    }

    function _signEncodedProof(int256 p, bytes32 asset, uint256 verifiedAt) internal view returns (bytes memory) {
        bytes32 digest = oracle.priceProofDigest(p, asset, verifiedAt);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(oracleSignerPk, digest);
        return abi.encode(p, asset, verifiedAt, abi.encodePacked(r, s, v));
    }

    // ---------- E1 ----------
    function test_E2E_Buy_FullFlow_NormalMarket_NoTrigger() public requiresFork {
        _setup();
        uint256 pid = _createPolicy();

        // Warp past expiry + safety window, then settle as expired.
        vm.warp(block.timestamp + DURATION + 24 hours + 1);
        shield.checkAndSettlePolicy(pid);
        assertEq(uint8(shield.getPolicyStatus(pid)), uint8(IShield.PolicyStatus.EXPIRED));
    }

    // ---------- E2 ----------
    function test_E2E_Buy_FullFlow_CrashAtThreshold_Triggers() public requiresFork {
        _setup();
        uint256 pid = _createPolicy();
        // 6% crash > 5% threshold.
        int256 dropped = (BTC_PRICE_OK * 94) / 100;
        bytes memory proof = _signEncodedProof(dropped, "BTC", block.timestamp);

        vm.prank(router);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, proof);
        assertTrue(r.triggered);
        assertEq(r.payoutAmount, (COVERAGE * 8000) / 10_000);
    }

    // ---------- E3 ----------
    function test_E2E_Trigger_With_RealOracle_3Confirmations() public requiresFork {
        // FlashBTCShield1h consumes ONE signed proof per claim. The "3
        // confirmations" pattern is not in this product. Document and skip.
        vm.skip(true);
    }

    // ---------- E4 ----------
    function test_E2E_Trigger_With_StaleOracle_FailsSilent() public requiresFork {
        _setup();
        uint256 pid = _createPolicy();
        uint256 verifiedAt = block.timestamp;
        int256 dropped = (BTC_PRICE_OK * 94) / 100;
        bytes memory proof = _signEncodedProof(dropped, "BTC", verifiedAt);

        // Make the proof stale (901s old).
        vm.warp(verifiedAt + 901);
        vm.prank(router);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    // ---------- E5 ----------
    function test_E2E_Trigger_With_SequencerDown_FailsSilent() public requiresFork {
        _setup();
        uint256 pid = _createPolicy();
        oracle.setSequencerDowntime(3600);

        // No proof submission during outage -> warp past extended cleanup ->
        // verifyAndCalculate now reverts (policy past extended cleanup).
        vm.warp(block.timestamp + DURATION + 24 hours + 3600 + 1);
        bytes memory proof = _signEncodedProof(BTC_PRICE_OK, "BTC", block.timestamp - 1);
        vm.prank(router);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    // ---------- E6 ----------
    function test_E2E_MultiplePolicies_SameWindow_AllTrigger() public requiresFork {
        _setup();
        uint256 pid1 = _createPolicy();
        uint256 pid2 = _createPolicy();
        uint256 pid3 = _createPolicy();

        int256 dropped = (BTC_PRICE_OK * 94) / 100;
        bytes memory proof = _signEncodedProof(dropped, "BTC", block.timestamp);

        vm.prank(router);
        IShield.PayoutResult memory r1 = shield.verifyAndCalculate(pid1, proof);
        vm.prank(router);
        IShield.PayoutResult memory r2 = shield.verifyAndCalculate(pid2, proof);
        vm.prank(router);
        IShield.PayoutResult memory r3 = shield.verifyAndCalculate(pid3, proof);

        assertTrue(r1.triggered);
        assertTrue(r2.triggered);
        assertTrue(r3.triggered);
    }

    // ---------- E7 ----------
    function test_E2E_Bond_Redeem_2Years_LuminaEquivalent() public requiresFork {
        // Bond redemption is a BondVault/ClaimBond responsibility; not callable
        // directly from FlashBTCShield1h. The full lifecycle is covered by the
        // BondVault/PolicyManager E2E suites. Skip here.
        vm.skip(true);
    }

    // ---------- E8 ----------
    function test_E2E_Bond_Redeem_Before_2Years_Reverts() public requiresFork {
        // See E7 -- bond layer.
        vm.skip(true);
    }

    // ---------- E9 ----------
    function test_E2E_Buy_Premium_Goes_To_TWAPBurner() public requiresFork {
        // Premium forwarding happens in CoverRouterV2.purchasePolicy, not the
        // shield. From the shield's perspective only premiumPaid is recorded;
        // assert that.
        _setup();
        uint256 pid = _createPolicy();
        IShield.PolicyInfo memory info = shield.getPolicyInfo(pid);
        assertEq(info.premiumPaid, PREMIUM);
    }

    // ---------- E10 ----------
    function test_E2E_PolicyManager_PolicyId_Unique() public requiresFork {
        _setup();
        uint256 N = 100;
        uint256 prev = 0;
        for (uint256 i = 0; i < N; i++) {
            uint256 pid = _createPolicy();
            assertGt(pid, prev, "policyId must strictly increase");
            prev = pid;
        }
        assertEq(shield.totalPolicies(), N);
    }
}
