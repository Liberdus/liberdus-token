const { expect } = require("chai");
const { ethers } = require("hardhat");
const { ZeroAddress } = ethers;

describe("LiberdusToken", function () {
  let LiberdusToken;
  let liberdus;
  let owner;
  let signer1;
  let signer2;
  let signer3;
  let recipient;
  let bridgeInCaller;
  let signers;

  async function requestAndSignOperation(operationType, target, value, data) {
    const tx = await liberdus.requestOperation(operationType, target, value, data);
    const receipt = await tx.wait();
    
    const operationRequestedEvent = receipt.logs.find(log => log.fragment.name === 'OperationRequested');
    const operationId = operationRequestedEvent.args.operationId;

    for (let i = 0; i < signers.length; i++) {
      const messageHash = await liberdus.getOperationHash(operationId);
      const signature = await signers[i].signMessage(ethers.getBytes(messageHash));
      await liberdus.connect(signers[i]).submitSignature(operationId, signature);
    }
  }

  beforeEach(async function () {
    const accounts = await ethers.getSigners();
    [owner, signer1, signer2, signer3, recipient, bridgeInCaller] = accounts;
    signers = [owner, signer1, signer2]; // Use the first three accounts as signers

    const LiberdusToken = await ethers.getContractFactory("Liberdus");
    liberdus = await LiberdusToken.deploy([owner.address, signer1.address, signer2.address]);
    await liberdus.waitForDeployment();
  });

  it("Should deploy the contract correctly", async function () {
    expect(await liberdus.name()).to.equal("Liberdus Token");
    expect(await liberdus.symbol()).to.equal("LIB");
  });

  it("Should allow first mint and prevent immediate second mint", async function () {
    await requestAndSignOperation(0, ZeroAddress, 0, "0x");
    
    const totalSupply = await liberdus.totalSupply();
    expect(ethers.formatUnits(totalSupply, 18)).to.equal("3000000.0");

    await expect(
      requestAndSignOperation(0, ZeroAddress, 0, "0x")
    ).to.be.revertedWith("Mint interval not reached");

    const totalSupplyAfterSecondMint = await liberdus.totalSupply();
    expect(ethers.formatUnits(totalSupplyAfterSecondMint, 18)).to.equal("3000000.0");
  });

  it("Should set bridge in caller correctly", async function () {
    await requestAndSignOperation(5, bridgeInCaller.address, 0, "0x");
    
    const setCallerAddress = await liberdus.bridgeInCaller();
    expect(setCallerAddress).to.equal(bridgeInCaller.address);
  });

  it("Should change to post-launch mode", async function () {
    expect(await liberdus.isPreLaunch()).to.be.true;

    await requestAndSignOperation(2, ZeroAddress, 0, "0x");
    
    expect(await liberdus.isPreLaunch()).to.be.false;
  });

  it("Should allow bridging in and out in post-launch mode", async function () {
    // Change to post-launch mode
    await requestAndSignOperation(2, ZeroAddress, 0, "0x");

    // Set bridge in caller
    await requestAndSignOperation(5, bridgeInCaller.address, 0, "0x");

    // Bridge in
    const bridgeInAmount = ethers.parseUnits("1000", 18);
    await liberdus.connect(bridgeInCaller).bridgeIn(recipient.address, bridgeInAmount, ethers.id("testTxId"));

    let recipientBalance = await liberdus.balanceOf(recipient.address);
    expect(ethers.formatUnits(recipientBalance, 18)).to.equal("1000.0");

    // Bridge out
    const bridgeOutAmount = ethers.parseUnits("500", 18);
    await liberdus.connect(recipient).bridgeOut(bridgeOutAmount, owner.address);

    recipientBalance = await liberdus.balanceOf(recipient.address);
    expect(ethers.formatUnits(recipientBalance, 18)).to.equal("500.0");
  });
});