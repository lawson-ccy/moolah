// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./BaseInvariantTest.sol";

contract StaticInvariantTest is BaseInvariantTest {
  /* INVARIANTS */

  function invariantHealthy() public view {
    address[] memory users = targetSenders();

    for (uint256 i; i < allMarketParams.length; ++i) {
      MarketParams memory _marketParams = allMarketParams[i];

      for (uint256 j; j < users.length; ++j) {
        assertTrue(_isHealthy(_marketParams, users[j]));
      }
    }
  }
}
