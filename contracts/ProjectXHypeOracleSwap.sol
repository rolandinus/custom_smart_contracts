// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IERC20ProjectXMinimal {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

interface IProjectXUniswapV3PoolMinimal {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint32 feeProtocol,
            bool unlocked
        );

    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

contract ProjectXHypeOracleSwap {
    uint160 private constant MIN_SQRT_RATIO = 4295128739;
    uint160 private constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;
    uint256 private constant Q192 = 1 << 192;
    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant FEE_DENOMINATOR = 1_000_000;
    uint256 private constant WHYPE_RAW_UNIT = 1e18;
    uint256 private constant USDC_RAW_UNIT = 1e6;
    uint32 private constant HYPE_PERP_INDEX = 159;
    bytes32 private constant HYPE_COIN_HASH = keccak256("HYPE");

    address public constant HYPEREVM_ORACLE_PRECOMPILE = 0x0000000000000000000000000000000000000807;
    address public constant HYPEREVM_PERP_ASSET_INFO_PRECOMPILE = 0x000000000000000000000000000000000000080a;
    address public constant PROJECTX_WHYPE = 0x5555555555555555555555555555555555555555;
    address public constant PROJECTX_USDC = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;
    address public constant PROJECTX_POOL_005 = 0x6c9A33E3b592C0d65B3Ba59355d5Be0d38259285;
    address public constant PROJECTX_POOL_030 = 0x422e586C906eb241f784B4F5a633c2C7e59A2F54;

    struct PerpAssetInfo {
        string coin;
        uint32 marginTableId;
        uint8 szDecimals;
        uint8 maxLeverage;
        bool onlyIsolated;
    }

    struct PoolConfig {
        address pool;
        uint24 fee;
    }

    struct SwapResult {
        int256 amount0;
        int256 amount1;
    }

    address public immutable owner;
    address public immutable whype;
    address public immutable usdc;
    address public immutable oracle;
    address public immutable perpAssetInfoOracle;
    PoolConfig public pool005;
    PoolConfig public pool030;

    address private activePool;
    address private activeTokenIn;
    bool private activeZeroForOne;

    event SwapExecuted(
        address indexed caller,
        bool indexed usdcToWhype,
        uint256 amountIn,
        uint256 amountOut
    );
    event PoolSwapExecuted(
        address indexed pool,
        bool indexed usdcToWhype,
        uint160 sqrtPriceLimitX96,
        uint256 amountIn,
        uint256 amountOut
    );
    event TokenRecovered(address indexed owner, address indexed token, address indexed to, uint256 amount);

    error CallbackTokenMismatch();
    error InvalidAmountIn();
    error InvalidOracleAsset();
    error InvalidOraclePrice();
    error InvalidOracleScale();
    error InvalidProfitBps();
    error NoExecutablePool();
    error OracleAssetInfoCallFailed();
    error OracleCallFailed();
    error OwnableUnauthorized(address caller);
    error PoolTokenMismatch(address pool);
    error SafeTransferFailed();
    error UnauthorizedCallback(address caller);

    constructor(
        address whype_,
        address usdc_,
        address oracle_,
        address perpAssetInfoOracle_,
        address pool005_,
        address pool030_
    ) {
        owner = msg.sender;
        whype = whype_;
        usdc = usdc_;
        oracle = oracle_;
        perpAssetInfoOracle = perpAssetInfoOracle_;
        pool005 = PoolConfig({pool: pool005_, fee: 500});
        pool030 = PoolConfig({pool: pool030_, fee: 3000});

        _validatePoolTokens(pool005_);
        _validatePoolTokens(pool030_);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert OwnableUnauthorized(msg.sender);
        }
        _;
    }

    function swap(
        bool usdcToWhype,
        uint256 maxAmountIn,
        uint32 profitBps
    ) external onlyOwner returns (uint256 totalAmountIn, uint256 totalAmountOut) {
        if (maxAmountIn == 0 || maxAmountIn > uint256(type(int256).max)) {
            revert InvalidAmountIn();
        }
        if (profitBps >= BPS_DENOMINATOR) {
            revert InvalidProfitBps();
        }

        uint256 oraclePrice = _readHypePerpOraclePrice();
        uint8 hypeSzDecimals = _readHypePerpSzDecimals();
        address tokenIn = usdcToWhype ? usdc : whype;
        bool zeroForOne = !usdcToWhype;

        uint160 target005 = _targetSqrtPriceX96(oraclePrice, hypeSzDecimals, profitBps, pool005.fee, usdcToWhype);
        uint160 target030 = _targetSqrtPriceX96(oraclePrice, hypeSzDecimals, profitBps, pool030.fee, usdcToWhype);
        bool execute005 = _isExecutable(pool005.pool, zeroForOne, target005);
        bool execute030 = _isExecutable(pool030.pool, zeroForOne, target030);

        if (!execute005 && !execute030) {
            revert NoExecutablePool();
        }

        _safeTransferFrom(tokenIn, msg.sender, address(this), maxAmountIn);

        uint256 remaining = maxAmountIn;
        if (execute005) {
            (uint256 amountIn, uint256 amountOut) =
                _executePoolSwap(pool005.pool, msg.sender, tokenIn, zeroForOne, remaining, target005);
            totalAmountIn += amountIn;
            totalAmountOut += amountOut;
            remaining -= amountIn;
            emit PoolSwapExecuted(pool005.pool, usdcToWhype, target005, amountIn, amountOut);
        }

        if (remaining > 0 && execute030) {
            (uint256 amountIn, uint256 amountOut) =
                _executePoolSwap(pool030.pool, msg.sender, tokenIn, zeroForOne, remaining, target030);
            totalAmountIn += amountIn;
            totalAmountOut += amountOut;
            remaining -= amountIn;
            emit PoolSwapExecuted(pool030.pool, usdcToWhype, target030, amountIn, amountOut);
        }

        if (remaining > 0) {
            _safeTransfer(tokenIn, msg.sender, remaining);
        }

        emit SwapExecuted(msg.sender, usdcToWhype, totalAmountIn, totalAmountOut);
    }

    function recoverToken(address token, address to, uint256 amount) external onlyOwner {
        _safeTransfer(token, to, amount);
        emit TokenRecovered(msg.sender, token, to, amount);
    }

    function quoteTargetSqrtPriceX96(
        uint256 oraclePrice,
        uint8 hypeSzDecimals,
        uint32 profitBps,
        uint24 fee,
        bool usdcToWhype
    ) external pure returns (uint160) {
        if (profitBps >= BPS_DENOMINATOR) {
            revert InvalidProfitBps();
        }

        return _targetSqrtPriceX96(oraclePrice, hypeSzDecimals, profitBps, fee, usdcToWhype);
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
        address poolAddress,
        address recipient,
        address tokenIn,
        bool zeroForOne,
        uint256 maxAmountIn,
        uint160 sqrtPriceLimitX96
    ) private returns (uint256 amountIn, uint256 amountOut) {
        activePool = poolAddress;
        activeTokenIn = tokenIn;
        activeZeroForOne = zeroForOne;

        SwapResult memory result;
        (result.amount0, result.amount1) =
            IProjectXUniswapV3PoolMinimal(poolAddress).swap(
                recipient,
                zeroForOne,
                int256(maxAmountIn),
                sqrtPriceLimitX96,
                ""
            );

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
    }

    function _isExecutable(address poolAddress, bool zeroForOne, uint160 sqrtPriceLimitX96)
        private
        view
        returns (bool)
    {
        (uint160 currentSqrtPriceX96,,,,,,) = IProjectXUniswapV3PoolMinimal(poolAddress).slot0();

        if (zeroForOne) {
            return sqrtPriceLimitX96 < currentSqrtPriceX96 && sqrtPriceLimitX96 > MIN_SQRT_RATIO;
        }

        return sqrtPriceLimitX96 > currentSqrtPriceX96 && sqrtPriceLimitX96 < MAX_SQRT_RATIO;
    }

    function _targetSqrtPriceX96(
        uint256 oraclePrice,
        uint8 hypeSzDecimals,
        uint32 profitBps,
        uint24 fee,
        bool usdcToWhype
    )
        private
        pure
        returns (uint160)
    {
        if (oraclePrice == 0) {
            revert InvalidOraclePrice();
        }
        if (hypeSzDecimals > 6 || fee >= FEE_DENOMINATOR) {
            revert InvalidOracleScale();
        }

        uint256 numerator = oraclePrice * USDC_RAW_UNIT;
        uint256 denominator = _pow10(6 - hypeSzDecimals) * WHYPE_RAW_UNIT;
        if (usdcToWhype) {
            numerator *= BPS_DENOMINATOR - profitBps;
            numerator *= FEE_DENOMINATOR - fee;
            denominator *= BPS_DENOMINATOR;
            denominator *= FEE_DENOMINATOR;
        } else {
            numerator *= BPS_DENOMINATOR + profitBps;
            numerator *= FEE_DENOMINATOR;
            denominator *= BPS_DENOMINATOR;
            denominator *= FEE_DENOMINATOR - fee;
        }

        uint256 priceX192 = usdcToWhype
            ? _mulDiv(numerator, Q192, denominator)
            : _mulDivRoundingUp(numerator, Q192, denominator);
        uint256 sqrtPriceX96 = usdcToWhype ? _sqrt(priceX192) : _sqrtRoundingUp(priceX192);
        if (sqrtPriceX96 <= MIN_SQRT_RATIO || sqrtPriceX96 >= MAX_SQRT_RATIO) {
            revert InvalidOraclePrice();
        }

        return uint160(sqrtPriceX96);
    }

    function _readHypePerpOraclePrice() private view returns (uint256) {
        (bool success, bytes memory returnData) = oracle.staticcall(abi.encode(HYPE_PERP_INDEX));
        if (!success || returnData.length < 32) {
            revert OracleCallFailed();
        }

        uint256 price = abi.decode(returnData, (uint64));
        if (price == 0) {
            revert InvalidOraclePrice();
        }

        return price;
    }

    function _readHypePerpSzDecimals() private view returns (uint8) {
        (bool success, bytes memory returnData) = perpAssetInfoOracle.staticcall(abi.encode(HYPE_PERP_INDEX));
        if (!success || returnData.length < 32) {
            revert OracleAssetInfoCallFailed();
        }

        PerpAssetInfo memory assetInfo = abi.decode(returnData, (PerpAssetInfo));
        if (keccak256(bytes(assetInfo.coin)) != HYPE_COIN_HASH) {
            revert InvalidOracleAsset();
        }
        if (assetInfo.szDecimals > 6) {
            revert InvalidOracleScale();
        }

        return assetInfo.szDecimals;
    }

    function _pow10(uint256 exponent) private pure returns (uint256 result) {
        result = 1;
        for (uint256 i = 0; i < exponent; ++i) {
            result *= 10;
        }
    }

    function _validatePoolTokens(address poolAddress) private view {
        IProjectXUniswapV3PoolMinimal pool = IProjectXUniswapV3PoolMinimal(poolAddress);
        if (pool.token0() != whype || pool.token1() != usdc) {
            revert PoolTokenMismatch(poolAddress);
        }
    }

    function _safeTransfer(address token, address to, uint256 value) private {
        (bool success, bytes memory returnData) =
            token.call(abi.encodeCall(IERC20ProjectXMinimal.transfer, (to, value)));
        if (!success || (returnData.length != 0 && !abi.decode(returnData, (bool)))) {
            revert SafeTransferFailed();
        }
    }

    function _safeTransferFrom(address token, address from, address to, uint256 value) private {
        (bool success, bytes memory returnData) =
            token.call(abi.encodeCall(IERC20ProjectXMinimal.transferFrom, (from, to, value)));
        if (!success || (returnData.length != 0 && !abi.decode(returnData, (bool)))) {
            revert SafeTransferFailed();
        }
    }

    function _sqrt(uint256 x) private pure returns (uint256 z) {
        if (x == 0) {
            return 0;
        }

        uint256 y = x;
        z = 1;
        if (y >= 0x100000000000000000000000000000000) {
            y >>= 128;
            z <<= 64;
        }
        if (y >= 0x10000000000000000) {
            y >>= 64;
            z <<= 32;
        }
        if (y >= 0x100000000) {
            y >>= 32;
            z <<= 16;
        }
        if (y >= 0x10000) {
            y >>= 16;
            z <<= 8;
        }
        if (y >= 0x100) {
            y >>= 8;
            z <<= 4;
        }
        if (y >= 0x10) {
            y >>= 4;
            z <<= 2;
        }
        if (y >= 0x8) {
            z <<= 1;
        }

        unchecked {
            z = (z + x / z) >> 1;
            z = (z + x / z) >> 1;
            z = (z + x / z) >> 1;
            z = (z + x / z) >> 1;
            z = (z + x / z) >> 1;
            z = (z + x / z) >> 1;
            z = (z + x / z) >> 1;
            uint256 roundedDown = x / z;
            return z < roundedDown ? z : roundedDown;
        }
    }

    function _sqrtRoundingUp(uint256 x) private pure returns (uint256) {
        uint256 z = _sqrt(x);
        return z * z == x ? z : z + 1;
    }

    function _mulDiv(uint256 a, uint256 b, uint256 denominator) private pure returns (uint256 result) {
        unchecked {
            uint256 prod0;
            uint256 prod1;
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            if (prod1 == 0) {
                return prod0 / denominator;
            }

            require(denominator > prod1);

            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            uint256 twos = denominator & (~denominator + 1);
            assembly {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            uint256 inverse = (3 * denominator) ^ 2;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;

            result = prod0 * inverse;
            return result;
        }
    }

    function _mulDivRoundingUp(uint256 a, uint256 b, uint256 denominator) private pure returns (uint256) {
        uint256 result = _mulDiv(a, b, denominator);
        if (mulmod(a, b, denominator) > 0) {
            result += 1;
        }
        return result;
    }
}
