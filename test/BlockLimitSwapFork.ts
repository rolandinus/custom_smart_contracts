import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { network } from "hardhat";
import { encodeAbiParameters, getAddress, keccak256, parseUnits, toHex } from "viem";

const MAINNET_WETH_USDC_005_POOL = "0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640";
const WETH = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
const USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
const WETH_BALANCE_SLOT = 3n;
const MAX_SQRT_RATIO_MINUS_ONE = 1461446703485210103287273052203988822378723970341n - 1n;

const forkDescribe = process.env.MAINNET_RPC_URL === undefined ? describe.skip : describe;

forkDescribe("BlockLimitSwapFork", async function () {
  const { viem, networkHelpers } = await network.create("hardhatMainnetFork");
  const publicClient = await viem.getPublicClient();

  async function nextBlockNumber() {
    return (await publicClient.getBlockNumber()) + 1n;
  }

  async function setWethBalance(account: `0x${string}`, amount: bigint) {
    const storageSlot = keccak256(
      encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [account, WETH_BALANCE_SLOT])
    );

    await networkHelpers.setStorageAt(WETH, storageSlot, toHex(amount, { size: 32 }));
  }

  it("executes WETH to USDC against the real mainnet Uniswap V3 pool", async function () {
    const [caller] = await viem.getWalletClients();
    const swapper = await viem.deployContract("BlockLimitSwap");
    const weth = await viem.getContractAt("MockERC20", WETH);
    const usdc = await viem.getContractAt("MockERC20", USDC);
    const pool = await viem.getContractAt("MockUniswapV3Pool", MAINNET_WETH_USDC_005_POOL);

    assert.equal(getAddress(await pool.read.token0()), getAddress(USDC));
    assert.equal(getAddress(await pool.read.token1()), getAddress(WETH));

    const maxAmountIn = parseUnits("0.01", 18);
    await setWethBalance(caller.account.address, maxAmountIn);
    await weth.write.approve([swapper.address, maxAmountIn]);

    const usdcBefore = await usdc.read.balanceOf([caller.account.address]);
    const targetBlock = await nextBlockNumber();

    await viem.assertions.emit(
      swapper.write.swap([
        WETH,
        MAINNET_WETH_USDC_005_POOL,
        MAX_SQRT_RATIO_MINUS_ONE,
        maxAmountIn,
        targetBlock,
        101n
      ]),
      swapper,
      "SwapExecuted"
    );

    const usdcAfter = await usdc.read.balanceOf([caller.account.address]);
    const wethAfter = await weth.read.balanceOf([caller.account.address]);

    assert(usdcAfter > usdcBefore);
    assert.equal(wethAfter, 0n);
    assert.equal(await weth.read.balanceOf([swapper.address]), 0n);
  });
});
