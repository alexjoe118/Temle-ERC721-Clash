const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("CFC Foken", function () {
  it("Should return the new greeting once it's changed", async function () {
    const CFC = await ethers.getContractFactory("CFC");
    const cfc = await CFC.deploy();
    await cfc.deployed();

    expect(
      await cfc.balanceOf("0x5FbDB2315678afecb367f032d93F642f64180aa3")
    ).to.equal(0);
    // const setGreetingTx = await greeter.setGreeting("Hola, mundo!");

    // // wait until the transaction is mined
    // await setGreetingTx.wait();

    // expect(await temple721.greet()).to.equal("Hola, mundo!");
  });
});
