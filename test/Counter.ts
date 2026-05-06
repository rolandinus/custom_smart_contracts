import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { network } from "hardhat";
import { getAddress } from "viem";

const { viem, networkHelpers } = await network.create();

describe("Counter", function () {
  async function deployCounterFixture() {
    const counter = await viem.deployContract("Counter");
    const [owner, otherAccount] = await viem.getWalletClients();

    return { counter, owner, otherAccount };
  }

  it("starts at zero and increments", async function () {
    const { counter, owner } = await networkHelpers.loadFixture(deployCounterFixture);

    assert.equal(await counter.read.count(), 0n);

    await viem.assertions.emitWithArgs(
      counter.write.increment(),
      counter,
      "Incremented",
      [getAddress(owner.account.address), 1n]
    );

    assert.equal(await counter.read.count(), 1n);
  });

  it("allows only the owner to reset", async function () {
    const { counter, otherAccount } = await networkHelpers.loadFixture(deployCounterFixture);

    await counter.write.increment();
    assert.equal(await counter.read.count(), 1n);

    await viem.assertions.revertWithCustomError(
      counter.write.reset({ account: otherAccount.account }),
      counter,
      "NotOwner"
    );

    await counter.write.reset();
    assert.equal(await counter.read.count(), 0n);
  });
});
