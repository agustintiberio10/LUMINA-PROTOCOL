// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {LuminaOracle} from "../src/oracles/LuminaOracle.sol";

contract MultisigOracleTest is Test {
    event SignerAdded(address indexed signer);
    event SignerRemoved(address indexed signer);
    event QuorumChanged(uint256 required);

    LuminaOracle oracle;

    // 5 test keys
    uint256 key1 = 0xA001;
    uint256 key2 = 0xA002;
    uint256 key3 = 0xA003;
    uint256 key4 = 0xA004;
    uint256 key5 = 0xA005;

    address signer1;
    address signer2;
    address signer3;
    address signer4;
    address signer5;

    address owner = address(this);

    function setUp() public {
        signer1 = vm.addr(key1);
        signer2 = vm.addr(key2);
        signer3 = vm.addr(key3);
        signer4 = vm.addr(key4);
        signer5 = vm.addr(key5);

        // Deploy oracle: owner=this, oracleKey=signer1, no sequencer feed
        oracle = new LuminaOracle(owner, signer1, address(0));
    }

    // ── BACKWARDS COMPATIBILITY ──

    function test_singleSignerWorksAsBeforeWithRequiredOne() public {
        bytes32 hash = keccak256("test data");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key1, hash);
        bytes memory sig = abi.encodePacked(r, s, v);

        address recovered = oracle.verifySignature(hash, sig);
        assertEq(recovered, signer1);
    }

    // ── SIGNER MANAGEMENT ──

    function test_initialSignerIsRegistered() public {
        assertTrue(oracle.isSigner(signer1));
        (uint256 required, uint256 total) = oracle.getSignerInfo();
        assertEq(required, 1);
        assertEq(total, 1);
    }

    function test_addSigner() public {
        oracle.addSigner(signer2);
        assertTrue(oracle.isSigner(signer2));
        (, uint256 total) = oracle.getSignerInfo();
        assertEq(total, 2);
    }

    function test_addSignerEmitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit SignerAdded(signer2);
        oracle.addSigner(signer2);
    }

    function test_cannotAddDuplicateSigner() public {
        oracle.addSigner(signer2);
        vm.expectRevert("Already a signer");
        oracle.addSigner(signer2);
    }

    function test_cannotAddZeroAddress() public {
        vm.expectRevert("Zero address");
        oracle.addSigner(address(0));
    }

    function test_removeSigner() public {
        oracle.addSigner(signer2);
        oracle.removeSigner(signer2);
        assertFalse(oracle.isSigner(signer2));
    }

    function test_cannotRemoveIfBreaksQuorum() public {
        vm.expectRevert("Would break quorum");
        oracle.removeSigner(signer1);
    }

    function test_onlyOwnerCanAddSigner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        oracle.addSigner(signer2);
    }

    function test_onlyOwnerCanRemoveSigner() public {
        oracle.addSigner(signer2);
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        oracle.removeSigner(signer2);
    }

    // ── QUORUM ──

    function test_setRequiredSignatures() public {
        oracle.addSigner(signer2);
        oracle.addSigner(signer3);
        oracle.setRequiredSignatures(2);
        (uint256 required,) = oracle.getSignerInfo();
        assertEq(required, 2);
    }

    function test_cannotSetRequiredAboveTotal() public {
        vm.expectRevert("Exceeds total signers");
        oracle.setRequiredSignatures(5);
    }

    function test_cannotSetRequiredToZero() public {
        vm.expectRevert("Must be > 0");
        oracle.setRequiredSignatures(0);
    }

    function test_setRequiredEmitsEvent() public {
        oracle.addSigner(signer2);
        vm.expectEmit(false, false, false, true);
        emit QuorumChanged(2);
        oracle.setRequiredSignatures(2);
    }

    // ── MULTISIG VERIFICATION ──

    function test_threeOfFiveMultisig() public {
        // Setup 5 signers, require 3
        oracle.addSigner(signer2);
        oracle.addSigner(signer3);
        oracle.addSigner(signer4);
        oracle.addSigner(signer5);
        oracle.setRequiredSignatures(3);

        bytes32 hash = keccak256("trigger data");
        bytes32 ethHash = hash;

        // Get 3 signatures, sorted by signer address ascending
        address[] memory signers = _sortSigners3(signer1, signer2, signer3);
        uint256[] memory keys = _getKeysForSigners(signers);

        bytes memory packed;
        for (uint256 i = 0; i < 3; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[i], ethHash);
            packed = abi.encodePacked(packed, r, s, v);
        }

        // verifySignature should return oracleKey (for BaseShield compatibility)
        address result = oracle.verifySignature(hash, packed);
        assertEq(result, signer1); // signer1 is the oracleKey
    }

    function test_failsWithTwoOfFiveWhenThreeRequired() public {
        oracle.addSigner(signer2);
        oracle.addSigner(signer3);
        oracle.addSigner(signer4);
        oracle.addSigner(signer5);
        oracle.setRequiredSignatures(3);

        bytes32 hash = keccak256("trigger data");
        bytes32 ethHash = hash;

        // Only 2 signatures
        address[] memory signers = _sortSigners2(signer1, signer2);
        uint256[] memory keys = _getKeysForSigners(signers);

        bytes memory packed;
        for (uint256 i = 0; i < 2; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[i], ethHash);
            packed = abi.encodePacked(packed, r, s, v);
        }

        vm.expectRevert("Not enough signatures");
        oracle.verifySignature(hash, packed);
    }

    function test_failsWithDuplicateSigner() public {
        oracle.addSigner(signer2);
        oracle.addSigner(signer3);
        oracle.setRequiredSignatures(3);

        bytes32 hash = keccak256("trigger data");
        bytes32 ethHash = hash;

        // Same key signs 3 times
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key1, ethHash);
        bytes memory sig = abi.encodePacked(r, s, v);
        bytes memory packed = abi.encodePacked(sig, sig, sig);

        vm.expectRevert("Signatures not ordered or duplicate");
        oracle.verifySignature(hash, packed);
    }

    function test_failsWithUnauthorizedSigner() public {
        oracle.addSigner(signer2);
        oracle.addSigner(signer3);
        oracle.setRequiredSignatures(3);

        bytes32 hash = keccak256("trigger data");
        bytes32 ethHash = hash;

        // Rogue key (not authorized)
        uint256 rogueKey = 0xDEAD;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(rogueKey, ethHash);
        bytes memory packed = abi.encodePacked(r, s, v);

        // Add 2 valid signatures
        (v, r, s) = vm.sign(key1, ethHash);
        packed = abi.encodePacked(packed, r, s, v);
        (v, r, s) = vm.sign(key2, ethHash);
        packed = abi.encodePacked(packed, r, s, v);

        vm.expectRevert(); // Unauthorized or ordering error
        oracle.verifySignature(hash, packed);
    }

    function test_packedMultisigDirectCall() public {
        oracle.addSigner(signer2);
        oracle.addSigner(signer3);
        oracle.setRequiredSignatures(3);

        bytes32 hash = keccak256("data");
        bytes32 ethHash = hash;

        // 3 sorted signatures
        address[] memory signers = _sortSigners3(signer1, signer2, signer3);
        uint256[] memory keys = _getKeysForSigners(signers);

        bytes memory packed;
        for (uint256 i = 0; i < 3; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[i], ethHash);
            packed = abi.encodePacked(packed, r, s, v);
        }

        assertTrue(oracle.verifyPackedMultisig(hash, packed));
    }

    function test_removeSignerEmitsEvent() public {
        oracle.addSigner(signer2);
        vm.expectEmit(true, false, false, false);
        emit SignerRemoved(signer2);
        oracle.removeSigner(signer2);
    }

    // ── HELPER FUNCTIONS ──

    function _sortSigners3(address a, address b, address c) internal pure returns (address[] memory) {
        address[] memory arr = new address[](3);
        arr[0] = a; arr[1] = b; arr[2] = c;
        for (uint256 i = 0; i < 3; i++) {
            for (uint256 j = i + 1; j < 3; j++) {
                if (uint160(arr[i]) > uint160(arr[j])) {
                    (arr[i], arr[j]) = (arr[j], arr[i]);
                }
            }
        }
        return arr;
    }

    function _sortSigners2(address a, address b) internal pure returns (address[] memory) {
        address[] memory arr = new address[](2);
        if (uint160(a) < uint160(b)) { arr[0] = a; arr[1] = b; }
        else { arr[0] = b; arr[1] = a; }
        return arr;
    }

    function _getKeysForSigners(address[] memory signers) internal view returns (uint256[] memory) {
        uint256[] memory keys = new uint256[](signers.length);
        for (uint256 i = 0; i < signers.length; i++) {
            if (signers[i] == signer1) keys[i] = key1;
            else if (signers[i] == signer2) keys[i] = key2;
            else if (signers[i] == signer3) keys[i] = key3;
            else if (signers[i] == signer4) keys[i] = key4;
            else if (signers[i] == signer5) keys[i] = key5;
        }
        return keys;
    }
}
