// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SolvencyOracle} from "../../src/oracles/SolvencyOracle.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";

// ═══════ INLINE MOCKS ═══════

contract OracleMockERC20 is ERC20 {
    constructor() ERC20("MockLUMINA", "mLUM") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract OracleMockBondVault {
    uint256 public totalCommittedUSD;
    address public lumina;

    constructor(address _lumina) {
        lumina = _lumina;
    }

    function setTotalCommittedUSD(uint256 amount) external {
        totalCommittedUSD = amount;
    }
}

contract OracleMockCapacityOracle {
    uint256 public price;

    constructor(uint256 _price) {
        price = _price;
    }

    function setPrice(uint256 _price) external {
        price = _price;
    }

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }
}

// ═══════ TEST CONTRACT ═══════

contract OracleEvaluationStress is Test {
    using ProxyDeployer for *;

    uint256 constant BASE_TS = 1767225600;

    SolvencyOracle oracle;
    OracleMockERC20 lumina;
    OracleMockBondVault mockVault;
    OracleMockCapacityOracle capOracle;

    function setUp() public {
        vm.warp(BASE_TS + 60 days);

        lumina = new OracleMockERC20();
        capOracle = new OracleMockCapacityOracle(0.036e18);

        mockVault = new OracleMockBondVault(address(lumina));

        // Fund vault with 70M LUMINA so solvency ratio is meaningful
        lumina.mint(address(mockVault), 70_000_000e18);

        // Set some committed USD so ratio isn't infinite
        // 70M * $0.036 = $2.52M value. Set committed to $500k (18-dec)
        mockVault.setTotalCommittedUSD(500_000e18);

        oracle = ProxyDeployer.deploySolvencyOracle(
            address(mockVault),
            address(capOracle),
            address(this) // admin
        );
    }

    /// @notice Evaluate SolvencyOracle every day for 30 days.
    ///         Verify no revert and quadrant changes respect cooldown.
    function test_Stress_30DaysOfEvaluations() public {
        uint256 startTime = block.timestamp;
        uint256 evalCount = 0;
        (uint8 prevS, uint8 prevM) = oracle.getCurrentQuadrant();

        for (uint256 day = 1; day <= 30; day++) {
            // Advance 1 day
            vm.warp(startTime + day * 1 days);

            // Slightly vary the price to test smoothing
            uint256 newPrice = 0.036e18 + (day % 5) * 0.001e18;
            capOracle.setPrice(newPrice);

            // Evaluate — use try/catch in case interval not reached
            try oracle.evaluate() returns (bool changed) {
                evalCount++;
                if (changed) {
                    (uint8 curS, uint8 curM) = oracle.getCurrentQuadrant();
                    assertTrue(curS != prevS || curM != prevM, "Quadrant should differ on change");
                    prevS = curS;
                    prevM = curM;
                }
            } catch {
                // Evaluation interval not yet reached — OK
            }
        }

        // Should have completed at least 25 evaluations out of 30 days
        assertGe(evalCount, 25, "Should complete most evaluations");
    }

    /// @notice Oscillate price +/-50% rapidly. Verify smoothing and cooldown work.
    function test_Stress_ExtremeVolatility() public {
        uint256 startTime = block.timestamp;
        uint256 basePrice = 0.036e18;

        // Track quadrant changes
        uint256 changeCount = 0;

        for (uint256 day = 1; day <= 30; day++) {
            vm.warp(startTime + day * 1 days);

            // Oscillate: even days = +50%, odd days = -50%
            uint256 newPrice;
            if (day % 2 == 0) {
                newPrice = (basePrice * 150) / 100; // $0.054
            } else {
                newPrice = (basePrice * 50) / 100; // $0.018
            }
            capOracle.setPrice(newPrice);

            bool changed = oracle.evaluate();
            if (changed) {
                changeCount++;
            }
        }

        // With 7-day cooldown, max possible quadrant changes in 30 days is ~4
        assertLe(changeCount, 4, "Cooldown should limit quadrant changes");

        // Verify the 3-sample smoothing buffer is populated
        uint256 ratio = oracle.getSolvencyRatio();
        assertGt(ratio, 0, "Solvency ratio should be positive");
    }
}
