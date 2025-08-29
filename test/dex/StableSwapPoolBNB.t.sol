// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { StableSwapPool } from "../../src/dex/StableSwapPool.sol";
import { StableSwapLP } from "../../src/dex/StableSwapLP.sol";
import { StableSwapPoolInfo } from "../../src/dex/StableSwapPoolInfo.sol";
import { ERC20Mock } from "../../src/moolah/mocks/ERC20Mock.sol";
import { IOracle } from "../../src/moolah/interfaces/IOracle.sol";

contract StableSwapPoolBNBTest is Test {
  address constant BNB_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

  StableSwapPool pool;
  StableSwapPoolInfo poolInfo;

  StableSwapLP lp; // ss-lp

  ERC20Mock token0;
  address token1 = BNB_ADDRESS;

  address admin = makeAddr("admin");
  address manager = makeAddr("manager");
  address pauser = makeAddr("pauser");
  address oracle = makeAddr("oracle");

  address userA = makeAddr("userA");
  address userB = makeAddr("userB");
  address userC = makeAddr("userC");

  function setUp() public {
    poolInfo = new StableSwapPoolInfo();

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
      abi.encodeWithSelector(
        impl.initialize.selector,
        tokens,
        _A,
        _fee,
        _adminFee,
        admin,
        manager,
        pauser,
        address(lp),
        oracle
      )
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

    assertTrue(pool.hasRole(pool.DEFAULT_ADMIN_ROLE(), admin));
    assertTrue(pool.hasRole(pool.MANAGER(), manager));
    assertTrue(pool.hasRole(pool.PAUSER(), pauser));
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

    uint256 userBBalance0Before = token0.balanceOf(userB);
    uint256 userBBalance1Before = userB.balance;

    vm.startPrank(userB);
    token0.approve(address(pool), 10000 ether);

    // Should revert because of price diff check
    vm.expectRevert("Price difference for token0 exceeds threshold");
    pool.exchange(0, 1, 100000 ether, 0); // 0: token0, 1: token1, amountIn: amount of token0 to swap, 0: min amount out

    // Should succeed
    pool.exchange(0, 1, 100 ether, 0);
    vm.stopPrank();

    // validate the price after swap
    uint256 oraclePrice0 = IOracle(oracle).peek(address(token0));
    uint256 oraclePrice1 = IOracle(oracle).peek(address(token1));

    uint256 token1PriceAfter = (100 ether * oraclePrice0) / pool.get_dy(0, 1, 100 ether);
    uint256 token0PriceAfter = (100 ether * oraclePrice1) / pool.get_dy(1, 0, 100 ether);

    assertGe(token1PriceAfter, (oraclePrice1 * 97) / 100); // 3% slippage tolerance
    assertLe(token1PriceAfter, (oraclePrice1 * 103) / 100); // 3% slippage tolerance

    assertGe(token0PriceAfter, (oraclePrice0 * 97) / 100); // 3% slippage tolerance
    assertLe(token0PriceAfter, (oraclePrice0 * 103) / 100); // 3% slippage tolerance
    uint256 userBBalance0After = token0.balanceOf(userB);
    uint256 userBBalance1After = userB.balance;
    assertEq(userBBalance0After, userBBalance0Before - 100 ether);
    assertGe(userBBalance1After, userBBalance1Before + amountOut);
  }

  function test_remove_liquidity() public {
    test_seeding();

    vm.startPrank(userA);

    // remove liquidity
    uint256[2] memory min_amounts = poolInfo.calc_coins_amount(address(pool), 1 ether);
    lp.approve(address(pool), 1 ether);

    uint256 spotPrice0 = pool.get_dy(1, 0, 1e12); // token0 per token1; use tiny dx
    uint256 spotPrice1 = pool.get_dy(0, 1, 1e12); // token1 per token0

    uint256 userABalance0Before = token0.balanceOf(userA);
    uint256 userABalance1Before = userA.balance;
    uint256 token0ReserveBefore = pool.balances(0);
    uint256 token1ReserveBefore = pool.balances(1);
    uint256 totalSupply = lp.totalSupply();
    pool.remove_liquidity(1 ether, min_amounts);
    uint256 userABalance0After = token0.balanceOf(userA);
    uint256 userABalance1After = userA.balance;

    assertGe(userABalance0After, userABalance0Before + min_amounts[0]);
    assertGe(userABalance1After, userABalance1Before + min_amounts[1]);

    vm.stopPrank();
    // check reserves decreased
    assertEq(pool.balances(0), token0ReserveBefore - (userABalance0After - userABalance0Before));
    assertEq(pool.balances(1), token1ReserveBefore - (userABalance1After - userABalance1Before));
    assertEq(lp.totalSupply(), totalSupply - 1 ether);
    // spot price should not move
    uint256 spotPrice0After = pool.get_dy(1, 0, 1e12); // token0 per token1
    uint256 spotPrice1After = pool.get_dy(0, 1, 1e12); // token1 per token0

    assertApproxEqAbs(spotPrice0After, spotPrice0, 2); // allow 2 wei difference
    assertApproxEqAbs(spotPrice1After, spotPrice1, 2); // allow 2 wei difference
  }

  function test_remove_liquidity_one_coin() public {
    test_seeding();

    vm.startPrank(userA);

    // remove liquidity; recieving Bnb only

    (uint256 swapFee, uint256 adminFee) = poolInfo.get_remove_liquidity_one_coin_fee(address(pool), 1 ether, 1); // withdraw token0
    uint256 expectBnbAmt = pool.calc_withdraw_one_coin(1 ether, 1);

    lp.approve(address(pool), 1 ether);
    uint256 userABalance0Before = token0.balanceOf(userA);
    uint256 userABalance1Before = userA.balance;
    uint256 token0ReserveBefore = pool.balances(0);
    uint256 token1ReserveBefore = pool.balances(1);
    uint256 totalSupply = lp.totalSupply();

    pool.remove_liquidity_one_coin(1 ether, 1, expectBnbAmt);
    uint256 userABalance0After = token0.balanceOf(userA);
    uint256 userABalance1After = userA.balance;
    vm.stopPrank();

    assertEq(userABalance0After, userABalance0Before);
    assertEq(userABalance1After, userABalance1Before + expectBnbAmt);

    // check fee and reserves
    // TODO validate the fee amount
    assertEq(pool.balances(0), token0ReserveBefore);
    assertEq(pool.balances(1), token1ReserveBefore - expectBnbAmt - adminFee); // admin fee deducted from the pool
    assertEq(lp.totalSupply(), totalSupply - 1 ether);
  }

  function test_remove_liquidity_imbalance() public {
    test_seeding();

    vm.startPrank(userA);

    // remove liquidity imbalanced
    uint256[2] memory amounts = [uint256(100 ether), uint256(50 ether)]; // withdraw 100 slisBnb and 50 Bnb

    uint256[2] memory liquidityFee = poolInfo.get_remove_liquidity_imbalance_fee(address(pool), amounts);
    uint256 maxBurnAmount = pool.calc_token_amount(amounts, false);

    lp.approve(address(pool), maxBurnAmount);

    uint256 userABalance0Before = token0.balanceOf(userA);
    uint256 userABalance1Before = userA.balance;
    uint256 token0ReserveBefore = pool.balances(0);
    uint256 token1ReserveBefore = pool.balances(1);
    uint256 totalSupply = lp.totalSupply();

    pool.remove_liquidity_imbalance(amounts, maxBurnAmount);
    uint256 userABalance0After = token0.balanceOf(userA);
    uint256 userABalance1After = userA.balance;
    vm.stopPrank();

    assertEq(userABalance0After, userABalance0Before + amounts[0] - liquidityFee[0]);
    assertEq(userABalance1After, userABalance1Before + amounts[1] - liquidityFee[1]);

    // check fee and reserves
    // TODO validate the fee amount
    //    assertEq(pool.balances(0), token0ReserveBefore - 100 ether);
    //    assertEq(pool.balances(1), token1ReserveBefore - adminFee); // admin fee deducted from the pool
    assertEq(lp.totalSupply(), totalSupply - maxBurnAmount);
  }

  function test_paused() public {
    test_seeding();

    vm.prank(pauser);
    pool.pause();
    assertTrue(pool.paused());

    vm.startPrank(userB);
    token0.approve(address(pool), 10000 ether);

    vm.expectRevert("EnforcedPause()");
    pool.exchange(0, 1, 100 ether, 0);

    deal(userB, 100 ether);

    vm.expectRevert("EnforcedPause()");
    uint256[2] memory amounts = [uint256(1 ether), uint256(1 ether)];
    pool.add_liquidity{ value: 1 ether }(amounts, 0);

    vm.expectRevert("EnforcedPause()");
    pool.remove_liquidity_one_coin(1 ether, 0, 0);

    vm.expectRevert("EnforcedPause()");
    pool.remove_liquidity_imbalance(amounts, 0);
    vm.stopPrank();

    vm.startPrank(userA);
    // remove liquidity should work when paused
    lp.approve(address(pool), 1 ether);
    uint256[2] memory min_amounts = [uint256(0), uint256(0)];
    pool.remove_liquidity(1 ether, min_amounts);
    vm.stopPrank();
  }
}
