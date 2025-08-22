// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import { IProvider } from "./interfaces/IProvider.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { MarketParamsLib } from "../moolah/libraries/MarketParamsLib.sol";
import { SharesMathLib } from "../moolah/libraries/SharesMathLib.sol";
import { IMoolahVault } from "../moolah-vault/interfaces/IMoolahVault.sol";
import { Id, IMoolah, MarketParams, Market } from "../moolah/interfaces/IMoolah.sol";
import { ErrorsLib } from "../moolah/libraries/ErrorsLib.sol";
import { UtilsLib } from "../moolah/libraries/UtilsLib.sol";

import { IStableSwap, IStableSwapPoolInfo, StableSwapType } from "../dex/interfaces/IStableSwap.sol";
import { IStableSwapLPCollateral } from "../dex/interfaces/IStableSwapLPCollateral.sol";
import { IOracle, TokenConfig } from "../moolah/interfaces/IOracle.sol";

/**
 * @title SmartProvider
 * @author Lista DAO
 * @notice SmartProvider is a contract that allows users to supply collaterals to Lista Lending while simultaneously earning swap fees.
 */
contract SmartProvider is UUPSUpgradeable, AccessControlEnumerableUpgradeable, IOracle, IProvider {
  using SafeERC20 for IERC20;
  using MarketParamsLib for MarketParams;
  using SharesMathLib for uint256;

  /* IMMUTABLES */
  IMoolah public immutable MOOLAH;
  /// @dev stableswap LP Collateral token
  address public immutable TOKEN;

  /// @dev stableswap pool
  address public dex;

  /// @dev stableswap pool info contract
  address public dexInfo;

  /// @dev stableswap LP token
  address public dexLP;

  /// @dev resilient oracle address
  address public resilientOracle;

  address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
  address public constant BNB_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
  bytes32 public constant MANAGER = keccak256("MANAGER");

  /* ------------------ Events ------------------ */
  event SupplyCollateralPerfect(
    address indexed onBehalf,
    address indexed collateralToken,
    uint256 collateralAmount,
    uint256 amount0,
    uint256 amount1
  );

  event WithdrawCollateral(
    address indexed collateralToken,
    address indexed onBehalf,
    uint256 collateralAmount,
    uint256 minToken0Amount,
    uint256 minToken1Amount,
    address receiver
  );

  modifier onlyMoolah() {
    require(msg.sender == address(MOOLAH), "not moolah");
    _;
  }

  /* CONSTRUCTOR */

  /// @custom:oz-upgrades-unsafe-allow constructor
  /// @param moolah The address of the Moolah contract.
  /// @param dexLPCollateral The address of the stableswap LP collateral token.
  constructor(address moolah, address dexLPCollateral) {
    require(moolah != address(0), ErrorsLib.ZERO_ADDRESS);
    require(dexLPCollateral != address(0), ErrorsLib.ZERO_ADDRESS);

    MOOLAH = IMoolah(moolah);
    TOKEN = dexLPCollateral;

    _disableInitializers();
  }

  /// @param _admin The admin of the contract.
  /// @param _manager The manager of the contract.
  /// @param _dex The address of the stableswap pool.
  function initialize(
    address _admin,
    address _manager,
    address _dex,
    address _dexInfo,
    address _resilientOracle
  ) public initializer {
    require(_admin != address(0), ErrorsLib.ZERO_ADDRESS);
    require(_manager != address(0), ErrorsLib.ZERO_ADDRESS);
    require(_dex != address(0), ErrorsLib.ZERO_ADDRESS);
    require(_dexInfo != address(0), ErrorsLib.ZERO_ADDRESS);
    require(_resilientOracle != address(0), ErrorsLib.ZERO_ADDRESS);

    dex = _dex;
    dexInfo = _dexInfo;
    dexLP = IStableSwap(dex).token();
    require(dexLP != address(0), "invalid dex LP token");

    resilientOracle = _resilientOracle;
    _peek(token(0));
    _peek(token(1));

    __AccessControl_init();

    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    _grantRole(MANAGER, _manager);
  }

  /// @dev add liquidity to the stableswap pool according to proportions of amount0 and amount1
  function supplyCollateralPerfect(
    MarketParams calldata marketParams,
    address onBehalf,
    uint256 amount0,
    uint256 amount1,
    uint256 minLpAmount, // slippage tolerance
    bytes calldata data // pass to Moolah contract
  ) external payable {
    require(marketParams.collateralToken == TOKEN, "invalid collateral token");
    address token0 = token(0);
    address token1 = token(1);

    // validate msg.value, amount0 and amount1
    StableSwapType dexType = IStableSwapPoolInfo(dexInfo).stableSwapType(dex);
    require(
      (dexType == StableSwapType.BothERC20 && msg.value == 0 && amount0 > 0 && amount1 > 0) ||
        (dexType == StableSwapType.Token0Bnb && amount0 == msg.value && amount1 > 0) ||
        (dexType == StableSwapType.Token1Bnb && amount1 == msg.value && amount0 > 0),
      "invalid value or amounts"
    );

    // validate slippage before adding liquidity
    uint256 expectLpToMint = IStableSwapPoolInfo(dexInfo).get_add_liquidity_mint_amount(dex, [amount0, amount1]);
    require(expectLpToMint >= minLpAmount, "slippage too high");

    // add liquidity to the stableswap pool
    uint256 actualLpAmount = IERC20(dexLP).balanceOf(address(this));
    if (dexType == StableSwapType.BothERC20) {
      IERC20(token0).safeIncreaseAllowance(dex, amount0);
      IERC20(token1).safeIncreaseAllowance(dex, amount1);

      IERC20(token0).safeTransferFrom(msg.sender, address(this), amount0);
      IERC20(token1).safeTransferFrom(msg.sender, address(this), amount1);

      IStableSwap(dex).add_liquidity([amount0, amount1], minLpAmount);
    } else if (dexType == StableSwapType.Token0Bnb) {
      IERC20(token1).safeIncreaseAllowance(dex, amount1);
      IERC20(token1).safeTransferFrom(msg.sender, address(this), amount1);

      IStableSwap(dex).add_liquidity{ value: amount0 }([amount0, amount1], minLpAmount);
    } else if (dexType == StableSwapType.Token1Bnb) {
      IERC20(token0).safeIncreaseAllowance(dex, amount0);
      IERC20(token0).safeTransferFrom(msg.sender, address(this), amount0);

      IStableSwap(dex).add_liquidity{ value: amount1 }([amount0, amount1], minLpAmount);
    }

    // validate the actual LP amount minted
    actualLpAmount = IERC20(dexLP).balanceOf(address(this)) - actualLpAmount;
    require(actualLpAmount >= minLpAmount, "slippage too high");

    // 1:1 mint collateral token
    IStableSwapLPCollateral(TOKEN).mint(address(this), actualLpAmount);

    // supply collateral to moolah
    IERC20(TOKEN).safeIncreaseAllowance(address(MOOLAH), actualLpAmount);
    MOOLAH.supplyCollateral(marketParams, actualLpAmount, onBehalf, data);

    emit SupplyCollateralPerfect(onBehalf, TOKEN, actualLpAmount, amount0, amount1);
  }

  function withdrawCollateral(
    MarketParams calldata marketParams,
    uint256 collateralAmount,
    uint256 minToken0Amount, // slippage tolerance
    uint256 minToken1Amount, // slippage tolerance
    address onBehalf,
    address payable receiver
  ) external {
    require(collateralAmount > 0, "zero withdrawal amount");
    require(receiver != address(0), ErrorsLib.ZERO_ADDRESS);
    require(isSenderAuthorized(msg.sender, onBehalf), "unauthorized sender");
    require(marketParams.collateralToken == TOKEN, "invalid collateral token");

    // validate slippage before removing liquidity
    uint256[2] memory expectAmount = IStableSwapPoolInfo(dexInfo).calc_coins_amount(dex, collateralAmount);
    require(minToken0Amount <= expectAmount[0], "Invalid token0 amount");
    require(minToken1Amount <= expectAmount[1], "Invalid token1 amount");

    uint256 token0Amount = getTokenBalance(0);
    uint256 token1Amount = getTokenBalance(1);

    // remove liquidity from the stableswap pool
    IStableSwap(dex).remove_liquidity(collateralAmount, [minToken0Amount, minToken1Amount]);

    // validate the actual token amounts after removing liquidity
    token0Amount = getTokenBalance(0) - token0Amount;
    token1Amount = getTokenBalance(1) - token1Amount;
    require(token0Amount >= minToken0Amount, "slippage too high for token0");
    require(token1Amount >= minToken1Amount, "slippage too high for token1");

    // withdraw collateral
    MOOLAH.withdrawCollateral(marketParams, collateralAmount, onBehalf, address(this));

    // burn collateral token
    IStableSwapLPCollateral(TOKEN).burn(address(this), collateralAmount);

    if (token0Amount > 0) transferOutTo(0, token0Amount, receiver);
    if (token1Amount > 0) transferOutTo(1, token1Amount, receiver);

    emit WithdrawCollateral(TOKEN, onBehalf, collateralAmount, minToken0Amount, minToken1Amount, receiver);
  }

  /**
   * @dev Transfers the specified amount of the token at index `i` to the receiver.
   * @param i The index of the token (0 or 1).
   * @param amount The amount of the token to transfer.
   * @param receiver The address to receive the tokens.
   */
  function transferOutTo(uint256 i, uint256 amount, address payable receiver) private {
    address token = token(i);

    if (token == BNB_ADDRESS) {
      // if token is BNB, transfer BNB
      (bool success, ) = receiver.call{ value: amount }("");
      require(success, "Transfer BNB failed");
    } else {
      // if token is ERC20, transfer ERC20
      IERC20(token).safeTransfer(receiver, amount);
    }
  }

  /// @dev empty function to allow moolah to do liquidation
  /// @dev may support burn clisBnb in the future (mint clisBnb by providing BNB)
  function liquidate(Id id, address borrower) external onlyMoolah {}

  /// @dev Returns whether the sender is authorized to manage `onBehalf`'s positions.
  /// @param sender The address of the sender to check.
  /// @param onBehalf The address of the position owner.
  function isSenderAuthorized(address sender, address onBehalf) public view returns (bool) {
    return sender == onBehalf || MOOLAH.isAuthorized(onBehalf, sender);
  }

  /// @param i The index of the token (0 or 1).
  function getTokenBalance(uint256 i) public view returns (uint256) {
    address token = token(i);
    StableSwapType dexType = IStableSwapPoolInfo(dexInfo).stableSwapType(dex);

    if (i == 0) {
      return dexType == StableSwapType.Token0Bnb ? address(this).balance : IERC20(token).balanceOf(address(this));
    } else if (i == 1) {
      return dexType == StableSwapType.Token1Bnb ? address(this).balance : IERC20(token).balanceOf(address(this));
    } else {
      revert("Invalid token index");
    }
  }

  /// @dev Returns the address of the token at index `i`.
  function token(uint256 i) public view returns (address) {
    require(i < 2, "Invalid token index");
    return IStableSwap(dex).coins(i);
  }

  /// @dev Returns the price of the token in 8 decimal format.
  function peek(address token) external view returns (uint256) {
    if (token == TOKEN) {
      // if token is dexLP, return the price of the LP token
      uint256[2] memory amounts = IStableSwapPoolInfo(dexInfo).calc_coins_amount(dex, 1 ether);
      uint256 price0 = _peek(IStableSwap(dex).coins(0));
      uint256 price1 = _peek(IStableSwap(dex).coins(1));

      return (amounts[0] * price0 + amounts[1] * price1) / 1 ether; // 1 ether is the LP token amount
    }

    return _peek(token);
  }

  function _peek(address token) private view returns (uint256) {
    if (token == BNB_ADDRESS) {
      return IOracle(resilientOracle).peek(WBNB);
    } else {
      return IOracle(resilientOracle).peek(token);
    }
  }

  /// @dev Returns the oracle configuration for the specified token.
  function getTokenConfig(address token) external view returns (TokenConfig memory) {
    if (token == TOKEN) {
      return
        TokenConfig({
          asset: TOKEN,
          oracles: [address(this), address(0), address(0)],
          enableFlagsForOracles: [true, false, false],
          timeDeltaTolerance: 0
        });
    }

    if (token == BNB_ADDRESS) {
      return IOracle(resilientOracle).getTokenConfig(WBNB);
    } else {
      return IOracle(resilientOracle).getTokenConfig(token);
    }
  }

  receive() external payable {}

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
