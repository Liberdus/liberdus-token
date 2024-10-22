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

    chainId = BigInt((await ethers.provider.getNetwork()).chainId);

    const LiberdusToken = await ethers.getContractFactory("Liberdus");
    liberdus = await LiberdusToken.deploy([owner.address, signer1.address, signer2.address], chainId);
    await liberdus.waitForDeployment();
  });

  it("Should deploy the contract correctly", async function () {
    expect(await liberdus.name()).to.equal("Liberdus");
    expect(await liberdus.symbol()).to.equal("LBD");
    expect(await liberdus.getChainId()).to.equal(chainId);
  });

  it("Should prevent signature replay from another signer", async function () {
    const operationType = 0; // Mint operation
    const target = owner.address;
    const value = 0;
    const data = "0x";

    // Request operation
    const tx = await liberdus.requestOperation(operationType, target, value, data);
    const receipt = await tx.wait();
    
    const operationRequestedEvent = receipt.logs.find(log => log.fragment.name === 'OperationRequested');
    const operationId = operationRequestedEvent.args.operationId;

    // Get owner's signature
    const messageHash = await liberdus.getOperationHash(operationId);
    const ownerSignature = await owner.signMessage(ethers.getBytes(messageHash));

    // Try to submit owner's signature through signer1 (another valid signer)
    await expect(
      liberdus.connect(signer1).submitSignature(operationId, ownerSignature)
    ).to.be.revertedWith("Signature signer must be message sender");

    // Verify operation hasn't been executed
    const operation = await liberdus.operations(operationId);
    expect(operation.executed).to.be.false;
    expect(operation.numSignatures).to.equal(0);
  });

  it("Should validate correct signer is submitting their own signature", async function () {
    const operationType = 0; // Mint operation
    const target = owner.address;
    const value = 0;
    const data = "0x";

    // Request operation
    const tx = await liberdus.requestOperation(operationType, target, value, data);
    const receipt = await tx.wait();
    
    const operationRequestedEvent = receipt.logs.find(log => log.fragment.name === 'OperationRequested');
    const operationId = operationRequestedEvent.args.operationId;

    // Get signatures from all signers
    const signatures = [];
    for (let i = 0; i < signers.length; i++) {
      const messageHash = await liberdus.getOperationHash(operationId);
      signatures[i] = await signers[i].signMessage(ethers.getBytes(messageHash));
    }

    // Try to submit signer2's signature through signer1
    // This should fail before the signer check because signer1 hasn't submitted their own signature yet
    await expect(
      liberdus.connect(signer1).submitSignature(operationId, signatures[2])
    ).to.be.revertedWith("Signature signer must be message sender");

    // Submit signatures in order
    for (let i = 0; i < signers.length; i++) {
      await liberdus.connect(signers[i]).submitSignature(operationId, signatures[i]);
    }

    // Verify operation executed successfully after all valid signatures
    const operation = await liberdus.operations(operationId);
    expect(operation.executed).to.be.true;
    expect(operation.numSignatures).to.equal(signers.length);
  });

  it("Should allow first mint and prevent immediate second mint", async function () {
    await requestAndSignOperation(0, owner.address, 0, "0x");
    
    const totalSupply = await liberdus.totalSupply();
    expect(ethers.formatUnits(totalSupply, 18)).to.equal("3000000.0");

    await expect(
      requestAndSignOperation(0, owner.address, 0, "0x")
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
  it("Should allow bridging in and out in post-launch mode with correct chain ID", async function () {
    // Change to post-launch mode
    await requestAndSignOperation(2, ZeroAddress, 0, "0x");

    // Set bridge in caller
    await requestAndSignOperation(5, bridgeInCaller.address, 0, "0x");

    // Bridge in
    const bridgeInAmount = ethers.parseUnits("1000", 18);
    await liberdus.connect(bridgeInCaller).bridgeIn(recipient.address, bridgeInAmount, chainId, ethers.id("testTxId"));

    let recipientBalance = await liberdus.balanceOf(recipient.address);
    expect(ethers.formatUnits(recipientBalance, 18)).to.equal("1000.0");

    // Bridge out
    const bridgeOutAmount = ethers.parseUnits("500", 18);
    await liberdus.connect(recipient).bridgeOut(bridgeOutAmount, owner.address, chainId);

    // Check recipient balance after bridge out (should be reduced)
    recipientBalance = await liberdus.balanceOf(recipient.address);
    expect(ethers.formatUnits(recipientBalance, 18)).to.equal("500.0");

    // Check total supply (should be reduced after bridge out)
    const totalSupplyAfterBridgeOut = await liberdus.totalSupply();
    expect(ethers.formatUnits(totalSupplyAfterBridgeOut, 18)).to.equal("500.0");
  });

  it("Should not allow bridging in with incorrect chain ID", async function () {
    await requestAndSignOperation(2, ZeroAddress, 0, "0x");
    await requestAndSignOperation(5, bridgeInCaller.address, 0, "0x");

    const bridgeInAmount = ethers.parseUnits("1000", 18);
    const incorrectChainId = chainId + BigInt(1);

    await expect(
      liberdus.connect(bridgeInCaller).bridgeIn(recipient.address, bridgeInAmount, incorrectChainId, ethers.id("testTxId"))
    ).to.be.revertedWith("Invalid chain ID");
  });

  it("Should not allow bridging out with incorrect chain ID", async function () {
    await requestAndSignOperation(2, ZeroAddress, 0, "0x");
    
    const bridgeOutAmount = ethers.parseUnits("500", 18);
    const incorrectChainId = chainId + BigInt(1);

    await expect(
      liberdus.connect(recipient).bridgeOut(bridgeOutAmount, owner.address, incorrectChainId)
    ).to.be.revertedWith("Invalid chain ID");
  });
  
  it("Should include chain ID in operation hash", async function () {
    const operationType = 0; // Mint operation
    const target = owner.address;
    const value = 0;
    const data = "0x";

    const tx = await liberdus.requestOperation(operationType, target, value, data);
    const receipt = await tx.wait();
    
    const operationRequestedEvent = receipt.logs.find(log => log.fragment.name === 'OperationRequested');
    const operationId = operationRequestedEvent.args.operationId;

    const operationHash = await liberdus.getOperationHash(operationId);

    // Create a different instance of the contract with a different chain ID
    const differentChainId = chainId + BigInt(1);
    const LiberdusTokenDifferentChain = await ethers.getContractFactory("Liberdus");
    const liberdusDifferentChain = await LiberdusTokenDifferentChain.deploy([owner.address, signer1.address, signer2.address], differentChainId);
    await liberdusDifferentChain.waitForDeployment();

    // Get operation hash from the contract with different chain ID
    const operationHashDifferentChain = await liberdusDifferentChain.getOperationHash(operationId);

    // Verify that the operation hashes are different
    expect(operationHash).to.not.equal(operationHashDifferentChain);
  });
  it("Should execute burn operation correctly", async function () {
    // First mint some tokens
    await requestAndSignOperation(0, owner.address, 0, "0x");
    const initialSupply = await liberdus.totalSupply();
    
    // Burn half of the minted amount
    const burnAmount = initialSupply / BigInt(2);
    await requestAndSignOperation(1, owner.address, burnAmount, "0x");
    
    const finalSupply = await liberdus.totalSupply();
    expect(finalSupply).to.equal(initialSupply - burnAmount);
  });

  it("Should pause and unpause operations correctly", async function () {
    // First mint some tokens to test transfer
    await requestAndSignOperation(0, owner.address, 0, "0x");
    const amount = ethers.parseUnits("1000", 18);

    // Record owner's balance after mint (since mint goes to msg.sender)
    const ownerBalance = await liberdus.balanceOf(owner.address);
    expect(ownerBalance).to.be.gt(amount, "Owner should have sufficient balance");
    
    // Pause the contract
    await requestAndSignOperation(3, ZeroAddress, 0, "0x");
    
    // Try to transfer while paused
    await expect(
      liberdus.transfer(recipient.address, amount)
    ).to.be.revertedWithCustomError(liberdus, "EnforcedPause");

    // Unpause the contract
    await requestAndSignOperation(4, ZeroAddress, 0, "0x");
    
    // Transfer should work after unpause
    await expect(
      liberdus.transfer(recipient.address, amount)
    ).to.be.fulfilled;

    // Verify the transfer was successful
    expect(await liberdus.balanceOf(recipient.address)).to.equal(amount);
    expect(await liberdus.balanceOf(owner.address)).to.equal(ownerBalance - amount);
  });

  it("Should set bridge in limits correctly", async function () {
    const newMaxAmount = ethers.parseUnits("20000", 18);  // 20,000 tokens
    const newCooldown = BigInt(2 * 60);  // 2 minutes

    // Encode the cooldown parameter
    const encodedData = ethers.AbiCoder.defaultAbiCoder().encode(
      ['uint256'],
      [newCooldown]
    );

    await requestAndSignOperation(6, ZeroAddress, newMaxAmount, encodedData);
    
    expect(await liberdus.maxBridgeInAmount()).to.equal(newMaxAmount);
    expect(await liberdus.bridgeInCooldown()).to.equal(newCooldown);

    // Test the new limits
    await requestAndSignOperation(2, ZeroAddress, 0, "0x"); // Switch to post-launch
    await requestAndSignOperation(5, bridgeInCaller.address, 0, "0x"); // Set bridge caller

    // Try to bridge in more than the new limit
    const tooMuchAmount = ethers.parseUnits("20001", 18);
    await expect(
      liberdus.connect(bridgeInCaller).bridgeIn(recipient.address, tooMuchAmount, chainId, ethers.id("testTxId"))
    ).to.be.revertedWith("Amount exceeds bridge-in limit");

    // Bridge in valid amount
    const validAmount = ethers.parseUnits("19999", 18);
    await liberdus.connect(bridgeInCaller).bridgeIn(recipient.address, validAmount, chainId, ethers.id("testTxId"));

    // Try to bridge in again before cooldown
    await expect(
      liberdus.connect(bridgeInCaller).bridgeIn(recipient.address, validAmount, chainId, ethers.id("testTxId"))
    ).to.be.revertedWith("Bridge-in cooldown not met");
  });

  it("Should update signer correctly", async function () {
    const newSigner = recipient;  // Using recipient address as new signer
    const oldSigner = signer2;    // Replacing signer2

    // Request signer update operation
    const tx = await liberdus.requestOperation(7, oldSigner.address, BigInt(newSigner.address), "0x");
    const receipt = await tx.wait();
    
    const operationRequestedEvent = receipt.logs.find(log => log.fragment.name === 'OperationRequested');
    const operationId = operationRequestedEvent.args.operationId;

    // Only need 2 signatures for signer update
    for (let i = 0; i < 2; i++) {
      const messageHash = await liberdus.getOperationHash(operationId);
      const signature = await signers[i].signMessage(ethers.getBytes(messageHash));
      await liberdus.connect(signers[i]).submitSignature(operationId, signature);
    }

    // Verify new signer is set
    expect(await liberdus.isSigner(newSigner.address)).to.be.true;
    expect(await liberdus.isSigner(oldSigner.address)).to.be.false;

    // Try to use old signer for an operation
    const mintOp = await liberdus.requestOperation(0, owner.address, 0, "0x");
    const mintReceipt = await mintOp.wait();
    const mintOpId = mintReceipt.logs.find(log => log.fragment.name === 'OperationRequested').args.operationId;
    
    const oldSignerSignature = await oldSigner.signMessage(ethers.getBytes(await liberdus.getOperationHash(mintOpId)));
    await expect(
      liberdus.connect(oldSigner).submitSignature(mintOpId, oldSignerSignature)
    ).to.be.revertedWith("Only signers can submit signatures");
  });

  it("Should prevent signer being replaced from approving their own replacement", async function () {
    const newSigner = recipient;
    const oldSigner = signer2;

    const tx = await liberdus.requestOperation(7, oldSigner.address, BigInt(newSigner.address), "0x");
    const receipt = await tx.wait();
    
    const operationId = receipt.logs.find(log => log.fragment.name === 'OperationRequested').args.operationId;

    // Try to sign with the signer being replaced
    const messageHash = await liberdus.getOperationHash(operationId);
    const signature = await oldSigner.signMessage(ethers.getBytes(messageHash));
    
    await expect(
      liberdus.connect(oldSigner).submitSignature(operationId, signature)
    ).to.be.revertedWith("Signer being replaced cannot approve");
  });
});