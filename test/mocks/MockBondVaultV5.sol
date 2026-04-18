// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockBondVaultV5 {
    uint256 public totalCommittedUSD;
    address public lumina;
    uint256 public luminaBalanceStored;
    bool public revertOnDecrease;
    bool public revertOnBurn;

    constructor(address _lumina) {
        lumina = _lumina;
    }

    function setTotalCommittedUSD(uint256 amount) external {
        totalCommittedUSD = amount;
    }

    function setLuminaBalance(uint256 amount) external {
        luminaBalanceStored = amount;
    }

    function setRevertOnDecrease(bool r) external {
        revertOnDecrease = r;
    }

    function setRevertOnBurn(bool r) external {
        revertOnBurn = r;
    }

    function decreaseObligations(uint256 amount) external {
        require(!revertOnDecrease, "Mock: decrease revert");
        require(totalCommittedUSD >= amount, "Exceeds committed");
        totalCommittedUSD -= amount;
    }

    function burnFromReserves(uint256 amount) external {
        require(!revertOnBurn, "Mock: burn revert");
        require(luminaBalanceStored >= amount, "Exceeds balance");
        luminaBalanceStored -= amount;
    }
}
