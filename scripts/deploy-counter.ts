import { network } from "hardhat";

const { viem } = await network.create();

const counter = await viem.deployContract("Counter");

console.log(`Counter deployed to ${counter.address}`);
