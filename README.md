# Liberdus

Liberdus is a multi-signature ERC20 token with bridging capabilities, designed for both pre-launch and post-launch phases. It features controlled minting, burning, and cross-chain bridging functionalities.

## Features

- Multi-signature governance
- Pre-launch and post-launch modes
- Controlled minting with time intervals and supply cap
- Burning functionality
- Cross-chain bridging (in and out)
- Pausable transfers

## Prerequisites

- Node.js (v14.0.0 or later)
- npm (v6.0.0 or later)

## Installation

1. Clone the repository:
   ```
   git clone https://github.com/your-username/liberdus-token.git
   cd liberdus-token
   ```

2. Install dependencies:
   ```
   npm install
   ```

3. Create a `.env` file in the root directory and add your environment variables:
   ```
   MNEMONIC=your mnemonic phrase here
   MUMBAI_RPC_URL=https://rpc-mumbai.maticvigil.com
   PRIVATE_KEY=your_private_key_here
   POLYGONSCAN_API_KEY=your_polygonscan_api_key_here
   ```

## Usage

### Compiling Contracts

```
npx hardhat compile
```

### Running Tests

```
npx hardhat test
```

## Deployment

### Deploying to Local Hardhat Network

```
npx hardhat run scripts/deploy.js
```

### Deploying to Mumbai Testnet

Before deploying to Mumbai testnet, make sure you have set up your `.env` file with the necessary environment variables, including your `PRIVATE_KEY` and `MUMBAI_RPC_URL`.

```
npx hardhat run scripts/deploy.js --network mumbai
```

After deployment, the script will output the contract address and the initial signers. Make sure to save this information for future interactions with the contract.

If deploying to a public testnet or mainnet, the script will automatically attempt to verify the contract on Etherscan (or the equivalent block explorer) after deployment. Ensure you have set the appropriate API key in your `.env` file.

## Contract Functions

- `requestOperation`: Initiates a multi-sig operation
- `submitSignature`: Submits a signature for a pending operation
- `bridgeOut`: Bridges tokens out to another chain
- `bridgeIn`: Bridges tokens in from another chain
- `pause`: Pauses all token transfers
- `unpause`: Unpauses token transfers

## Security

This project utilizes OpenZeppelin contracts for enhanced security. However, it has not been audited. Use at your own risk.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgements

- OpenZeppelin for their secure smart contract libraries
- Hardhat for the Ethereum development environment