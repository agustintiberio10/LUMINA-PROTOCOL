// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract LuminaMerkleClaim is Ownable {
    IERC20 public immutable luminaToken;
    bytes32 public merkleRoot;

    mapping(address => uint256) public claimed;

    event Claimed(address indexed account, uint256 amount);
    event MerkleRootUpdated(bytes32 oldRoot, bytes32 newRoot);

    constructor(address _token) Ownable(msg.sender) {
        luminaToken = IERC20(_token);
    }

    function setMerkleRoot(bytes32 _root) external onlyOwner {
        bytes32 old = merkleRoot;
        merkleRoot = _root;
        emit MerkleRootUpdated(old, _root);
    }

    function claim(uint256 totalAmount, bytes32[] calldata proof) external {
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, totalAmount));
        require(MerkleProof.verify(proof, merkleRoot, leaf), "Invalid proof");

        uint256 alreadyClaimed = claimed[msg.sender];
        require(alreadyClaimed < totalAmount, "Already fully claimed");

        uint256 available = luminaToken.balanceOf(address(this));
        uint256 remaining = totalAmount - alreadyClaimed;
        uint256 toClaim = remaining > available ? available : remaining;

        require(toClaim > 0, "Nothing to claim");

        claimed[msg.sender] += toClaim;
        require(luminaToken.transfer(msg.sender, toClaim), "Transfer failed");

        emit Claimed(msg.sender, toClaim);
    }

    function claimable(address account, uint256 totalAmount, bytes32[] calldata proof)
        external
        view
        returns (uint256)
    {
        bytes32 leaf = keccak256(abi.encodePacked(account, totalAmount));
        if (!MerkleProof.verify(proof, merkleRoot, leaf)) return 0;

        uint256 alreadyClaimed = claimed[account];
        if (alreadyClaimed >= totalAmount) return 0;

        uint256 available = luminaToken.balanceOf(address(this));
        uint256 remaining = totalAmount - alreadyClaimed;
        return remaining > available ? available : remaining;
    }

    function availableTokens() external view returns (uint256) {
        return luminaToken.balanceOf(address(this));
    }
}
