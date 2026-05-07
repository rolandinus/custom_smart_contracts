// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

interface IUniswapV3PoolMinimal {
    function token0() external view returns (address);
    function token1() external view returns (address);

    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

contract BlockLimitSwap {
    struct SwapResult {
        int256 amount0;
        int256 amount1;
    }

    address public immutable owner;

    address private activePool;
    address private activeTokenIn;
    bool private activeZeroForOne;
    uint256 private randomNonce;

    event SwapExecuted(
        address indexed caller,
        address indexed tokenIn,
        address indexed pool,
        uint256 amountIn,
        uint256 amountOut
    );
    event TokenRecovered(address indexed owner, address indexed token, address indexed to, uint256 amount);

    error CallbackTokenMismatch();
    error InvalidAmountIn();
    error OwnableUnauthorized(address caller);
    error RandomGateNotPassed(uint256 executionPercentage);
    error SafeTransferFailed();
    error TokenNotInPool(address tokenIn, address pool);
    error UnauthorizedCallback(address caller);
    error WrongBlock(uint256 currentBlock, uint256 targetBlock);

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert OwnableUnauthorized(msg.sender);
        }
        _;
    }

    function swap(
        address tokenIn,
        address poolPairAddress,
        uint160 sqrtPriceLimitX96,
        uint256 maxAmountIn,
        uint256 targetBlock,
        uint256 executionPercentage
    ) external onlyOwner returns (uint256 amountIn, uint256 amountOut) {
        if (block.number != targetBlock) {
            revert WrongBlock(block.number, targetBlock);
        }
        if (!_shouldExecute(msg.sender, executionPercentage)) {
            revert RandomGateNotPassed(executionPercentage);
        }
        if (maxAmountIn > uint256(type(int256).max)) {
            revert InvalidAmountIn();
        }

        // Pool authenticity is intentionally verified by the surrounding off-chain framework.
        IUniswapV3PoolMinimal pool = IUniswapV3PoolMinimal(poolPairAddress);
        address token0 = pool.token0();
        address token1 = pool.token1();
        bool zeroForOne;

        if (tokenIn == token0) {
            zeroForOne = true;
        } else if (tokenIn == token1) {
            zeroForOne = false;
        } else {
            revert TokenNotInPool(tokenIn, poolPairAddress);
        }

        _safeTransferFrom(tokenIn, msg.sender, address(this), maxAmountIn);

        activePool = poolPairAddress;
        activeTokenIn = tokenIn;
        activeZeroForOne = zeroForOne;

        // sqrtPriceLimitX96 is externally calculated and is the sole price-protection input by design.
        SwapResult memory result = _executePoolSwap(pool, msg.sender, zeroForOne, maxAmountIn, sqrtPriceLimitX96);

        activePool = address(0);
        activeTokenIn = address(0);
        activeZeroForOne = false;

        if (zeroForOne) {
            amountIn = uint256(result.amount0);
            amountOut = uint256(-result.amount1);
        } else {
            amountIn = uint256(result.amount1);
            amountOut = uint256(-result.amount0);
        }

        uint256 refund = maxAmountIn - amountIn;
        if (refund > 0) {
            _safeTransfer(tokenIn, msg.sender, refund);
        }

        emit SwapExecuted(msg.sender, tokenIn, poolPairAddress, amountIn, amountOut);
    }

    function recoverToken(address token, address to, uint256 amount) external onlyOwner {
        _safeTransfer(token, to, amount);
        emit TokenRecovered(msg.sender, token, to, amount);
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (msg.sender != activePool) {
            revert UnauthorizedCallback(msg.sender);
        }

        if (activeZeroForOne) {
            if (amount0Delta <= 0 || amount1Delta > 0) {
                revert CallbackTokenMismatch();
            }
            _safeTransfer(activeTokenIn, msg.sender, uint256(amount0Delta));
        } else {
            if (amount1Delta <= 0 || amount0Delta > 0) {
                revert CallbackTokenMismatch();
            }
            _safeTransfer(activeTokenIn, msg.sender, uint256(amount1Delta));
        }
    }

    function _executePoolSwap(
        IUniswapV3PoolMinimal pool,
        address recipient,
        bool zeroForOne,
        uint256 maxAmountIn,
        uint160 sqrtPriceLimitX96
    ) private returns (SwapResult memory result) {
        (result.amount0, result.amount1) =
            pool.swap(recipient, zeroForOne, int256(maxAmountIn), sqrtPriceLimitX96, "");
    }

    function _shouldExecute(address user, uint256 executionPercentage) private returns (bool) {
        if (executionPercentage > 100) {
            return true;
        }

        uint256 randomValue = random(user, randomNonce);
        randomNonce += 1;
        return randomValue % 100 < executionPercentage;
    }

    function random(address user, uint256 nonce) internal view returns (uint256) {
        return uint256(keccak256(abi.encodePacked(block.prevrandao, block.timestamp, block.number, user, nonce)));
    }

    function _safeTransfer(address token, address to, uint256 value) private {
        (bool success, bytes memory returnData) =
            token.call(abi.encodeCall(IERC20Minimal.transfer, (to, value)));
        if (!success || (returnData.length != 0 && !abi.decode(returnData, (bool)))) {
            revert SafeTransferFailed();
        }
    }

    function _safeTransferFrom(address token, address from, address to, uint256 value) private {
        (bool success, bytes memory returnData) =
            token.call(abi.encodeCall(IERC20Minimal.transferFrom, (from, to, value)));
        if (!success || (returnData.length != 0 && !abi.decode(returnData, (bool)))) {
            revert SafeTransferFailed();
        }
    }
}
