import { network } from "hardhat";

const { viem } = await network.create();

const swapper = await viem.deployContract("BlockLimitSwap");

console.log(`BlockLimitSwap deployed to ${swapper.address}`);
