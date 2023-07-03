// SPDX-License-Identifier: GPLv2

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.

pragma solidity 0.8.7;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@uniswap/lib/contracts/libraries/Babylonian.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v3-core/contracts/libraries/LowGasSafeMath.sol";

/// @notice Add or remove liquidity from UniswapV2-like pools using just one of the pool tokens
abstract contract WidoZapper {
    using LowGasSafeMath for uint256;
    using SafeERC20 for IERC20;

    struct Asset {
        uint256 reserves;
        address token;
    }

    /// @notice Add liquidity to an Uniswap V2 pool using one of the pool tokens
    /// @param router Address of the UniswapV2Router02 contract
    /// @param pair Address of the pair contract to add liquidity into
    /// @param fromToken Address of the token to swap
    /// @param amount Amount of the from token to spend on the user's behalf
    /// @param minToToken Minimum amount of the pool token the user is willing to accept
    function zapIn(
        IUniswapV2Router02 router,
        IUniswapV2Pair pair,
        address fromToken,
        uint256 amount,
        uint256 minToToken,
        bytes memory extra
    ) external {
        IERC20(fromToken).safeTransferFrom(msg.sender, address(this), amount);

        uint256 toTokenAmount = _swapAndAddLiquidity(router, pair, fromToken, extra);
        require(toTokenAmount >= minToToken, "Slippage too high");

        IERC20(address(pair)).safeTransfer(msg.sender, toTokenAmount);
    }

    /// @notice Remove liquidity from an Uniswap V2 pool into one of the pool tokens
    /// @param router Address of the UniswapV2Router02 contract
    /// @param pair Address of the pair contract to remove liquidity from
    /// @param amount Amount of the lp token to spend on the user's behalf
    /// @param toToken Address of the to token
    /// @param minToToken Minimum amount of the to token the user is willing to accept
    function zapOut(
        IUniswapV2Router02 router,
        IUniswapV2Pair pair,
        uint256 amount,
        address toToken,
        uint256 minToToken,
        bytes memory extra
    ) external {
        IERC20(address(pair)).safeTransferFrom(msg.sender, address(this), amount);

        uint256 toTokenAmount = _removeLiquidityAndSwap(router, pair, toToken, extra);
        require(toTokenAmount >= minToToken, "Slippage too high");

        IERC20(toToken).safeTransfer(msg.sender, toTokenAmount);
    }

    /// @notice Calculate the amount of pool tokens received when adding liquidity to an UniswapV2 pool using a single asset
    /// @param router Address of the UniswapV2Router02 contract
    /// @param pair Address of the pair contract to add liquidity into
    /// @param fromToken Address of the from token
    /// @param amount Amount of the from token
    /// @return minToToken Minimum amount of the lp token the user would receive in a no-slippage scenario.
    function calcMinToAmountForZapIn(
        IUniswapV2Router02 router,
        IUniswapV2Pair pair,
        address fromToken,
        uint256 amount,
        bytes calldata extra
    ) external view returns (uint256 minToToken) {
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        Asset memory asset0 = Asset(reserve0, pair.token0());
        Asset memory asset1 = Asset(reserve1, pair.token1());

        // checking initial balance into `amount`, will be reusing the slot
        uint256 amount0 = IERC20(asset0.token).balanceOf(address(pair));
        uint256 amount1 = IERC20(asset1.token).balanceOf(address(pair));

        require(asset0.token == fromToken || asset1.token == fromToken, "Input token not present in liquidity pair");

        uint256 halfAmount0;
        uint256 halfAmount1;

        // stack too deep, so we can't store this bool
        if (asset0.token == fromToken) {
            halfAmount0 = amount / 2;
            halfAmount1 = _getAmountOut(router, halfAmount0, asset0, asset1, extra);
        } else {
            halfAmount1 = amount / 2;
            halfAmount0 = _getAmountOut(router, halfAmount1, asset1, asset0, extra);
        }

        amount0 = amount0 + halfAmount0 - reserve0;
        amount1 = amount1 + halfAmount1 - reserve1;

        uint256 lpTotalSupply = pair.totalSupply();
        return Math.min(amount0.mul(lpTotalSupply) / reserve0, amount1.mul(lpTotalSupply) / reserve1);
    }

    /// @notice Calculate the amount of to tokens received when removing liquidity from an UniswapV2 pool into a single asset.
    /// @param router Address of the UniswapV2Router02 contract
    /// @param pair Address of the pair contract to remove liquidity from
    /// @param toToken Address of the to token
    /// @param lpAmount Amount of the lp token
    /// @return minToToken Minimum amount of the to token the user would receive in a no-slippage scenario.
    function calcMinToAmountForZapOut(
        IUniswapV2Router02 router,
        IUniswapV2Pair pair,
        address toToken,
        uint256 lpAmount,
        bytes calldata extra
    ) external view returns (uint256 minToToken) {
        (uint256 reserve0, uint256 reserve1,) = pair.getReserves();
        uint256 lpTotalSupply = pair.totalSupply();

        bool isZapToToken0 = pair.token0() == toToken;
        require(isZapToToken0 || pair.token1() == toToken, "Input token not present in liquidity pair");

        uint256 amount0;
        uint256 amount1;
        Asset memory asset0 = Asset(reserve0, pair.token0());
        Asset memory asset1 = Asset(reserve1, pair.token1());

        if (isZapToToken0) {
            amount0 = (lpAmount * reserve0) / lpTotalSupply;
            amount1 = _getAmountOut(
                router,
                (lpAmount * reserve1) / lpTotalSupply,
                asset1, asset0,
                extra
            );
        } else {
            amount0 = _getAmountOut(
                router,
                (lpAmount * reserve0) / lpTotalSupply,
                asset0, asset1,
                extra
            );
            amount1 = (lpAmount * reserve1) / lpTotalSupply;
        }

        return amount0 + amount1;
    }

    function _removeLiquidityAndSwap(
        IUniswapV2Router02 router,
        IUniswapV2Pair pair,
        address toToken,
        bytes memory extra
    ) private returns (uint256) {
        _requires(router, pair);

        address token0 = pair.token0();
        address token1 = pair.token1();
        require(token0 == toToken || token1 == toToken, "Desired token not present in liquidity pair");

        IERC20(address(pair)).safeTransfer(
            address(pair),
            IERC20(address(pair)).balanceOf(address(this))
        );
        pair.burn(address(this));

        address swapToken = token1 == toToken
        ? token0
        : token1;

        address[] memory path = new address[](2);
        path[0] = swapToken;
        path[1] = toToken;

        _approveTokenIfNeeded(path[0], address(router));
        _swap(
            router,
            IERC20(swapToken).balanceOf(address(this)),
            path,
            extra
        );

        return IERC20(toToken).balanceOf(address(this));
    }

    function _swapAndAddLiquidity(
        IUniswapV2Router02 router,
        IUniswapV2Pair pair,
        address fromToken,
        bytes memory extra
    ) private returns (uint256) {
        _requires(router, pair);

        (uint256 reserveA, uint256 reserveB,) = pair.getReserves();

        bool isInputA = pair.token0() == fromToken;
        require(isInputA || pair.token1() == fromToken, "Input token not present in liquidity pair");

        address[] memory path = new address[](2);
        path[0] = fromToken;
        path[1] = isInputA
        ? pair.token1()
        : pair.token0();

        uint256 fullInvestment = IERC20(fromToken).balanceOf(address(this));
        uint256 swapAmountIn;
        if (isInputA) {
            swapAmountIn = _getAmountBToSwap(
                router,
                fullInvestment,
                Asset(reserveA, pair.token0()),
                Asset(reserveB, pair.token1()),
                extra
            );
        } else {
            swapAmountIn = _getAmountBToSwap(
                router,
                fullInvestment,
                Asset(reserveB, pair.token1()),
                Asset(reserveA, pair.token0()),
                extra
            );
        }

        _approveTokenIfNeeded(path[0], address(router));
        uint256[] memory swappedAmounts = _swap(
            router,
            swapAmountIn,
            path,
            extra
        );

        _approveTokenIfNeeded(path[1], address(router));
        (, , uint256 poolTokenAmount) = _addLiquidity(
            router,
            path[0],
            path[1],
            fullInvestment.sub(swappedAmounts[0]),
            swappedAmounts[1],
            extra
        );

        return poolTokenAmount;
    }

    function _getAmountBToSwap(
        IUniswapV2Router02 router,
        uint256 investmentA,
        Asset memory assetA,
        Asset memory assetB,
        bytes memory extra
    )
    internal pure
    returns (uint256 swapAmount) {
        uint256 halfInvestment = investmentA / 2;
        uint256 nominator = _getAmountOut(router, halfInvestment, assetA, assetB, extra);
        uint256 denominator = _quote(router, halfInvestment, assetA.reserves.add(halfInvestment), assetB.reserves.sub(nominator));
        swapAmount = investmentA.sub(Babylonian.sqrt((halfInvestment * halfInvestment * nominator) / denominator));
    }

    function _approveTokenIfNeeded(address token, address spender) private {
        if (IERC20(token).allowance(address(this), spender) == 0) {
            IERC20(token).safeApprove(spender, type(uint256).max);
        }
    }

    /** Virtual functions */

    /// @dev This function checks that the pair belongs to the factory
    function _requires(IUniswapV2Router02 router, IUniswapV2Pair pair)
    internal virtual;

    /// @dev This function quotes the expected amountB given a certain amountA, while the pool has the specified reserves
    function _quote(IUniswapV2Router02 router, uint256 amountA, uint256 reserveA, uint256 reserveB)
    internal pure virtual
    returns (uint256 amountB);

    /// @dev This function computes the amount out for a certain amount in
    function _getAmountOut(
        IUniswapV2Router02 router,
        uint256 amountIn,
        Asset memory assetIn,
        Asset memory assetOut,
        bytes memory extra
    )
    internal pure virtual
    returns (uint256 amountOut);

    /// @dev This function adds liquidity into the pool
    function _addLiquidity(
        IUniswapV2Router02 router,
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        bytes memory extra
    )
    internal virtual
    returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    /// @dev This function swap amountIn through the path
    function _swap(
        IUniswapV2Router02 router,
        uint256 amountIn,
        address[] memory path,
        bytes memory extra
    )
    internal virtual
    returns (uint256[] memory amounts);
}