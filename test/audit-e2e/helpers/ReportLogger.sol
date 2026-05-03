// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

/// @title ReportLogger
/// @notice Emits structured `console.log` output that the post-test parser
///         turns into REPORT-CERTIK-LEVEL-E2E.md sections.
abstract contract ReportLogger is Test {
    enum Sev { CRITICAL, HIGH, MEDIUM, LOW, INFO }

    function _logFinding(Sev sev, string memory tag, string memory msgText) internal pure {
        // Single-line format the bash post-processor can grep:
        //   FINDING|<sev>|<tag>|<msg>
        string memory s;
        if (sev == Sev.CRITICAL) s = "CRITICAL";
        else if (sev == Sev.HIGH) s = "HIGH";
        else if (sev == Sev.MEDIUM) s = "MEDIUM";
        else if (sev == Sev.LOW) s = "LOW";
        else s = "INFO";
        console2.log(string.concat("FINDING|", s, "|", tag, "|", msgText));
    }

    function logCritical(string memory tag, string memory msgText) internal pure { _logFinding(Sev.CRITICAL, tag, msgText); }
    function logHigh(string memory tag, string memory msgText) internal pure { _logFinding(Sev.HIGH, tag, msgText); }
    function logMedium(string memory tag, string memory msgText) internal pure { _logFinding(Sev.MEDIUM, tag, msgText); }
    function logLow(string memory tag, string memory msgText) internal pure { _logFinding(Sev.LOW, tag, msgText); }
    function logInfo(string memory tag, string memory msgText) internal pure { _logFinding(Sev.INFO, tag, msgText); }
}
