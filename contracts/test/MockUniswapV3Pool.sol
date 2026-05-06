// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IMockERC20 {
    function transfer(address to, uint256 value) external returns (bool);
}

interface IMockUniswapV3SwapCallback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

contract MockUniswapV3Pool {
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;

    bool public lastZeroForOne;
    uint160 public lastSqrtPriceLimitX96;
    int256 public lastAmountSpecified;
    address public lastRecipient;

    uint256 public nextAmountIn;
    uint256 public nextAmountOut;

    error InvalidExactInputAmount();

    constructor(address token0_, address token1_, uint24 fee_) {
        token0 = token0_;
        token1 = token1_;
        fee = fee_;
    }

    function setNextSwap(uint256 amountIn, uint256 amountOut) external {
        nextAmountIn = amountIn;
        nextAmountOut = amountOut;
    }

    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1) {
        if (amountSpecified <= 0) {
            revert InvalidExactInputAmount();
        }

        lastRecipient = recipient;
        lastZeroForOne = zeroForOne;
        lastAmountSpecified = amountSpecified;
        lastSqrtPriceLimitX96 = sqrtPriceLimitX96;

        uint256 amountIn = nextAmountIn;
        uint256 amountOut = nextAmountOut;

        if (zeroForOne) {
            amount0 = int256(amountIn);
            amount1 = -int256(amountOut);
            IMockUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
            IMockERC20(token1).transfer(recipient, amountOut);
        } else {
            amount0 = -int256(amountOut);
            amount1 = int256(amountIn);
            IMockUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
            IMockERC20(token0).transfer(recipient, amountOut);
        }
    }
}
