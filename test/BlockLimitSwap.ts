import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { network } from "hardhat";
import { encodeAbiParameters, getAddress, parseUnits } from "viem";

const { viem, networkHelpers } = await network.create();
const tokenAmount = (value: string) => parseUnits(value, 18);
const ALWAYS_EXECUTE = 101n;

async function nextBlockNumber() {
  const publicClient = await viem.getPublicClient();
  return (await publicClient.getBlockNumber()) + 1n;
}

describe("BlockLimitSwap", function () {
  async function deployFixture() {
    const [caller, other] = await viem.getWalletClients();
    const token0 = await viem.deployContract("MockERC20", ["Token Zero", "TK0", 18]);
    const token1 = await viem.deployContract("MockERC20", ["Token One", "TK1", 18]);
    const swapper = await viem.deployContract("BlockLimitSwap");
    const pool = await viem.deployContract("MockUniswapV3Pool", [
      token0.address,
      token1.address,
      3000
    ]);

    await token0.write.mint([caller.account.address, tokenAmount("100")]);
    await token1.write.mint([caller.account.address, tokenAmount("100")]);
    await token0.write.mint([pool.address, tokenAmount("100")]);
    await token1.write.mint([pool.address, tokenAmount("100")]);
    await token0.write.approve([swapper.address, tokenAmount("100")]);
    await token1.write.approve([swapper.address, tokenAmount("100")]);

    return { caller, other, token0, token1, swapper, pool };
  }

  it("reverts unless included in the target block", async function () {
    const { token0, swapper, pool } = await networkHelpers.loadFixture(deployFixture);
    const targetBlock = (await nextBlockNumber()) + 1n;

    await viem.assertions.revertWithCustomError(
      swapper.write.swap([
        token0.address,
        pool.address,
        123n,
        tokenAmount("10"),
        targetBlock + 1n,
        ALWAYS_EXECUTE
      ]),
      swapper,
      "WrongBlock"
    );
  });

  it("swaps token0 for token1 and refunds unused input", async function () {
    const { caller, token0, token1, swapper, pool } = await networkHelpers.loadFixture(deployFixture);
    const maxAmountIn = tokenAmount("10");
    const actualAmountIn = tokenAmount("4");
    const amountOut = tokenAmount("8");
    const sqrtPriceLimitX96 = 42n;

    await pool.write.setNextSwap([actualAmountIn, amountOut]);
    const targetBlock = await nextBlockNumber();

    await viem.assertions.emitWithArgs(
      swapper.write.swap([token0.address, pool.address, sqrtPriceLimitX96, maxAmountIn, targetBlock, ALWAYS_EXECUTE]),
      swapper,
      "SwapExecuted",
      [getAddress(caller.account.address), getAddress(token0.address), getAddress(pool.address), actualAmountIn, amountOut]
    );

    assert.equal(await pool.read.lastZeroForOne(), true);
    assert.equal(await pool.read.lastSqrtPriceLimitX96(), sqrtPriceLimitX96);
    assert.equal(await pool.read.lastAmountSpecified(), maxAmountIn);
    assert.equal(await pool.read.lastRecipient(), getAddress(caller.account.address));
    assert.equal(await token0.read.balanceOf([caller.account.address]), tokenAmount("96"));
    assert.equal(await token1.read.balanceOf([caller.account.address]), tokenAmount("108"));
    assert.equal(await token0.read.balanceOf([swapper.address]), 0n);
  });

  it("swaps token1 for token0", async function () {
    const { caller, token0, token1, swapper, pool } = await networkHelpers.loadFixture(deployFixture);
    const actualAmountIn = tokenAmount("3");
    const amountOut = tokenAmount("5");

    await pool.write.setNextSwap([actualAmountIn, amountOut]);
    const targetBlock = await nextBlockNumber();
    await viem.assertions.emitWithArgs(
      swapper.write.swap([token1.address, pool.address, 99n, tokenAmount("7"), targetBlock, ALWAYS_EXECUTE]),
      swapper,
      "SwapExecuted",
      [getAddress(caller.account.address), getAddress(token1.address), getAddress(pool.address), actualAmountIn, amountOut]
    );

    assert.equal(await pool.read.lastZeroForOne(), false);
    assert.equal(await token1.read.balanceOf([caller.account.address]), tokenAmount("97"));
    assert.equal(await token0.read.balanceOf([caller.account.address]), tokenAmount("105"));
    assert.equal(await token1.read.balanceOf([swapper.address]), 0n);
  });

  it("rejects tokens that are not in the pool", async function () {
    const { token0, swapper, pool } = await networkHelpers.loadFixture(deployFixture);
    const outsideToken = await viem.deployContract("MockERC20", ["Outside", "OUT", 18]);
    const targetBlock = await nextBlockNumber();

    await viem.assertions.revertWithCustomError(
      swapper.write.swap([outsideToken.address, pool.address, 1n, tokenAmount("1"), targetBlock, ALWAYS_EXECUTE]),
      swapper,
      "TokenNotInPool"
    );

    assert.equal(await token0.read.balanceOf([swapper.address]), 0n);
  });

  it("rejects callbacks when no swap is active", async function () {
    const { swapper, pool } = await networkHelpers.loadFixture(deployFixture);

    await viem.assertions.revertWithCustomError(
      swapper.write.uniswapV3SwapCallback([1n, -1n, encodeAbiParameters([{ type: "address" }], [pool.address])]),
      swapper,
      "UnauthorizedCallback"
    );
  });

  it("reverts before transferring tokens when the random execution percentage is zero", async function () {
    const { caller, token0, swapper, pool } = await networkHelpers.loadFixture(deployFixture);
    const targetBlock = await nextBlockNumber();

    await viem.assertions.revertWithCustomError(
      swapper.write.swap([token0.address, pool.address, 1n, tokenAmount("10"), targetBlock, 0n]),
      swapper,
      "RandomGateNotPassed"
    );

    assert.equal(await token0.read.balanceOf([caller.account.address]), tokenAmount("100"));
    assert.equal(await token0.read.balanceOf([swapper.address]), 0n);
    assert.equal(await pool.read.lastAmountSpecified(), 0n);
  });

  it("always executes when the random execution percentage is greater than 100", async function () {
    const { token0, swapper, pool } = await networkHelpers.loadFixture(deployFixture);
    const actualAmountIn = tokenAmount("1");
    const amountOut = tokenAmount("2");

    await pool.write.setNextSwap([actualAmountIn, amountOut]);
    const targetBlock = await nextBlockNumber();

    await viem.assertions.emit(
      swapper.write.swap([token0.address, pool.address, 1n, tokenAmount("10"), targetBlock, 101n]),
      swapper,
      "SwapExecuted"
    );
  });
});
