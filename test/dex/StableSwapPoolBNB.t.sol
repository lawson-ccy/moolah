// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { StableSwapPool } from "../../src/dex/StableSwapPool.sol";
import { StableSwapLP } from "../../src/dex/StableSwapLP.sol";
import { ERC20Mock } from "../../src/moolah/mocks/ERC20Mock.sol";
import { IOracle } from "../../src/moolah/interfaces/IOracle.sol";

contract StableSwapPoolBNBTest is Test {
  address constant BNB_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

  StableSwapPool pool;

  StableSwapLP lp; // ss-lp

  ERC20Mock token0;
  address token1 = BNB_ADDRESS;

  address admin = makeAddr("admin");
  address manager = makeAddr("manager");
  address oracle = makeAddr("oracle");

  address userA = makeAddr("userA");
  address userB = makeAddr("userB");
  address userC = makeAddr("userC");

  function setUp() public {
    // Deploy LP token
    StableSwapLP lpImpl = new StableSwapLP();
    ERC1967Proxy lpProxy = new ERC1967Proxy(address(lpImpl), abi.encodeWithSelector(lpImpl.initialize.selector));
    lp = StableSwapLP(address(lpProxy));

    token0 = new ERC20Mock();

    token0.setBalance(userA, 10000000 ether);
    deal(userA, 10000000 ether); // Give userA 10_000_000 BNB

    token0.setBalance(userB, 10000000 ether);
    deal(userC, 10000000 ether); // Give userC 10_000_000 BNB

    // initialize parameters
    address[2] memory tokens;
    tokens[0] = address(token0);
    tokens[1] = token1; // BNB_ADDRESS

    uint _A = 1000; // Amplification coefficient
    uint _fee = 1000000; // 0.01%; swap fee
    uint _adminFee = 5e9; // 50% swap fee goes to admin

    // mock oracle calls; token0 (slisBnb) price = $846.6; token1 (BNB) price = $830, rate = 1.02
    vm.mockCall(oracle, abi.encodeWithSelector(IOracle.peek.selector, address(token0)), abi.encode(8466e7));
    vm.mockCall(oracle, abi.encodeWithSelector(IOracle.peek.selector, token1), abi.encode(830e8));

    StableSwapPool impl = new StableSwapPool();
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, tokens, _A, _fee, _adminFee, admin, manager, address(lp), oracle)
    );

    pool = StableSwapPool(address(proxy));
    lp.setMinter(address(pool));

    assertEq(pool.coins(0), address(token0));
    assertEq(pool.coins(1), address(token1));
    assertEq(address(pool.token()), address(lp));

    assertEq(pool.initial_A(), _A);
    assertEq(pool.future_A(), _A);
    assertEq(pool.fee(), _fee);
    assertEq(pool.admin_fee(), _adminFee);
    assertTrue(pool.support_BNB());
    assertEq(pool.oracle(), oracle);
    assertEq(pool.price0DiffThreshold(), 3e16); // 3% price diff threshold
    assertEq(pool.price1DiffThreshold(), 3e16); // 3% price diff threshold
  }

  function test_seeding() public {
    vm.startPrank(userA);

    // Add liquidity
    uint ratio = (8466 * 10 ** 17) / 830; // slisBnb price ratio to BNB
    uint256 amount0 = 100_000 * ratio; // slisBnb amount, based on the price ratio
    uint256 amount1 = 100_000 ether; // Bnb

    // Approve tokens for the pool
    token0.approve(address(pool), amount0);

    uint min_mint_amount = 0;
    pool.add_liquidity{ value: amount1 }([amount0, amount1], min_mint_amount);
    console.log("User A added liquidity");

    // Check LP balance
    uint256 lpAmount = lp.balanceOf(userA);
    assertEq(lpAmount, 201999990107932736938407); // 2000 LP tokens minted (1:1 ratio for simplicity)

    assertEq(lp.totalSupply(), 201999990107932736938407); // Total supply of LP tokens

    vm.stopPrank();
  }

  function test_swap_token0_to_token1() public {
    test_seeding();

    uint amountIn = 1 ether; // Amount of token0 to swap

    uint256 amountOut = pool.get_dy(0, 1, amountIn); // expect token1 amount out

    vm.startPrank(userB);
    token0.approve(address(pool), 10000 ether);

    // Should revert because of price diff check
    vm.expectRevert("Price difference for token0 exceeds threshold");
    pool.exchange(0, 1, 100000 ether, 0); // 0: token0, 1: token1, amountIn: amount of token0 to swap, 0: min amount out

    // Should succeed
    pool.exchange(0, 1, 100 ether, 0);

    // validate the price after swap
    uint256 oraclePrice0 = IOracle(oracle).peek(address(token0));
    uint256 oraclePrice1 = IOracle(oracle).peek(address(token1));

    uint256 token1PriceAfter = (100 ether * oraclePrice0) / pool.get_dy(0, 1, 100 ether);
    uint256 token0PriceAfter = (100 ether * oraclePrice1) / pool.get_dy(1, 0, 100 ether);

    assertGe(token1PriceAfter, (oraclePrice1 * 97) / 100); // 3% slippage tolerance
    assertLe(token1PriceAfter, (oraclePrice1 * 103) / 100); // 3% slippage tolerance

    assertGe(token0PriceAfter, (oraclePrice0 * 97) / 100); // 3% slippage tolerance
    assertLe(token0PriceAfter, (oraclePrice0 * 103) / 100); // 3% slippage tolerance

    console.log("User B swapped token0 to token1");
  }
}
