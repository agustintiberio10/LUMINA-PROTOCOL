// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockMarketplace {
    struct MockListing {
        address seller;
        uint256 epochId;
        uint256 amount;
        uint256 priceUSDC;
        bool active;
    }

    mapping(uint256 => MockListing) public mockListings;
    bool public shouldRevertOnBuy;

    function setListing(uint256 id, address seller, uint256 epochId, uint256 amount, uint256 priceUSDC, bool active)
        external
    {
        mockListings[id] = MockListing(seller, epochId, amount, priceUSDC, active);
    }

    function setRevertOnBuy(bool r) external {
        shouldRevertOnBuy = r;
    }

    function getListing(uint256 id)
        external
        view
        returns (address seller, uint256 epochId, uint256 amount, uint256 priceUSDC, bool active)
    {
        MockListing memory l = mockListings[id];
        return (l.seller, l.epochId, l.amount, l.priceUSDC, l.active);
    }

    function executeBuy(uint256 id) external {
        require(!shouldRevertOnBuy, "Mock: buy revert");
        mockListings[id].active = false;
    }
}
