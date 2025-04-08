// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev The maximum fee a market can have (25%).
uint256 constant MAX_FEE = 0.25e18;

/// @dev Oracle price scale.
uint256 constant ORACLE_PRICE_SCALE = 1e36;

/// @dev Liquidation cursor.
uint256 constant LIQUIDATION_CURSOR = 0.3e18;

/// @dev Max liquidation incentive factor.
uint256 constant MAX_LIQUIDATION_INCENTIVE_FACTOR = 1.15e18;

/// @dev The EIP-712 typeHash for EIP712Domain.
bytes32 constant DOMAIN_TYPEHASH = keccak256("EIP712Domain(uint256 chainId,address verifyingContract)");

/// @dev The EIP-712 typeHash for Authorization.
bytes32 constant AUTHORIZATION_TYPEHASH = keccak256(
  "Authorization(address authorizer,address authorized,bool isAuthorized,uint256 nonce,uint256 deadline)"
);

uint128 constant DEFAULT_FEE = 0.05e18;
