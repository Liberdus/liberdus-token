const fs = require('fs');
const path = require('path');
const { parse } = require('csv-parse/sync');
const { ethers } = require('hardhat');

// ABI for ERC20 token - only including necessary functions
const ERC20_ABI = [
  "function transfer(address to, uint256 amount) external returns (bool)",
  "function balanceOf(address account) external view returns (uint256)",
  "function decimals() external view returns (uint8)",
  "function name() external view returns (string)",
  "function symbol() external view returns (string)"
];

async function validateContract(address, signer) {
  if (!ethers.isAddress(address)) {
    throw new Error('Invalid token address format');
  }

  const code = await signer.provider.getCode(address);
  if (code === '0x') {
    throw new Error('No contract found at the specified address');
  }

  try {
    const token = new ethers.Contract(address, ERC20_ABI, signer);

    const [name, symbol, decimals] = await Promise.all([
      token.name(),
      token.symbol(),
      token.decimals()
    ]);

    console.log('\nToken Contract Validation:');
    console.log(`Name: ${name}`);
    console.log(`Symbol: ${symbol}`);
    console.log(`Decimals: ${decimals}`);

    const balance = await token.balanceOf(signer.address);
    console.log(`Your balance: ${ethers.formatUnits(balance, decimals)} ${symbol}\n`);

    return token;
  } catch (error) {
    throw new Error(`Contract validation failed: ${error.message}`);
  }
}

async function main() {
  try {
    if (!fs.existsSync('./token-config.json')) {
      throw new Error('token-config.json not found. Please deploy the token first.');
    }
    const tokenConfig = JSON.parse(fs.readFileSync('./token-config.json', 'utf8'));

    const CONFIG = {
      tokenAddress: tokenConfig.tokenAddress,
      csvPath: "./distribution-list.csv",
      outputPath: "./distribution-records.json",
      minimumWaitTime: 10 * 60 * 1000, // 10 minutes in milliseconds
    };

    let distributionRecords = {};
    if (fs.existsSync(CONFIG.outputPath)) {
      distributionRecords = JSON.parse(fs.readFileSync(CONFIG.outputPath, 'utf8'));
    }

    const fileContent = fs.readFileSync(CONFIG.csvPath, 'utf8');
    const records = parse(fileContent, {
      columns: true,
      skip_empty_lines: true
    });

    const [signer] = await ethers.getSigners();
    console.log('Starting distribution process...');
    console.log(`Signer address: ${signer.address}`);
    console.log(`Token address: ${CONFIG.tokenAddress}`);

    console.log('\nValidating token contract...');
    const token = await validateContract(CONFIG.tokenAddress, signer);
    const decimals = await token.decimals();
    const symbol = await token.symbol();

    const initialBalance = await token.balanceOf(signer.address);
    console.log(`Initial token balance: ${ethers.formatUnits(initialBalance, decimals)} ${symbol}`);

    for (const record of records) {
      const { name, address, amount } = record;

      if (address.toLowerCase() === signer.address.toLowerCase()) {
        console.log(`Skipping ${name} (${address}): Cannot send to self`);
        continue;
      }

      if (!ethers.isAddress(address)) {
        console.log(`Invalid address for ${name}, skipping...`);
        continue;
      }

      if (distributionRecords[address]) {
        const lastDistribution = new Date(distributionRecords[address].timestamp);
        const timeDiff = Date.now() - lastDistribution.getTime();

        if (timeDiff < CONFIG.minimumWaitTime) {
          console.log(`Skipping ${name} (${address}): Distribution attempted too soon (${Math.floor(timeDiff/1000/60)} minutes ago)`);
          continue;
        }
      }

      try {
        const tokenAmount = ethers.parseUnits(amount.toString(), decimals);
        const balance = await token.balanceOf(signer.address);

        // Updated comparison for BigInt
        if (balance < tokenAmount) {
          throw new Error('Insufficient token balance');
        }

        console.log(`Sending ${amount} ${symbol} to ${name} (${address})...`);
        const tx = await token.transfer(address, tokenAmount);
        await tx.wait();

        distributionRecords[address] = {
          name,
          amount,
          txHash: tx.hash,
          timestamp: new Date().toISOString(),
          blockNumber: tx.blockNumber
        };

        fs.writeFileSync(
          CONFIG.outputPath,
          JSON.stringify(distributionRecords, null, 2)
        );

        console.log(`✓ Sent ${amount} ${symbol} to ${name}`);
        console.log(`Transaction hash: ${tx.hash}`);

        const recipientBalance = await token.balanceOf(address);
        console.log(`Recipient's new balance: ${ethers.formatUnits(recipientBalance, decimals)} ${symbol}\n`);

      } catch (error) {
        console.error(`Error sending tokens to ${name} (${address}):`, error.message);
      }
    }

    const finalBalance = await token.balanceOf(signer.address);
    console.log(`Final token balance: ${ethers.formatUnits(finalBalance, decimals)} ${symbol}`);
    console.log('Distribution process completed');

  } catch (error) {
    console.error('Error in distribution script:', error);
    process.exit(1);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
