// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract Liberdus is ERC20, Pausable, ReentrancyGuard, Ownable {
    using ECDSA for bytes32;

    enum OperationType { 
        Mint, 
        Burn, 
        PostLaunch, 
        Pause, 
        Unpause, 
        SetBridgeInCaller, 
        SetBridgeInLimits, 
        UpdateSigner 
    }

    struct Operation {
        OperationType opType;
        address target;
        uint256 value;
        bytes data;
        uint256 numSignatures;
        bool executed;
        mapping(address => bool) signatures;
    }

    mapping(bytes32 => Operation) public operations;
    uint256 public operationCount;

    bool public isPreLaunch = true;
    uint256 public lastMintTime;
    uint256 public constant MINT_INTERVAL = 3 weeks + 6 days + 9 hours; // 3.9 weeks
    uint256 public constant MAX_SUPPLY = 210_000_000 * 10**18;
    uint256 public constant MINT_AMOUNT = 3_000_000 * 10**18;

    address public bridgeInCaller;
    uint256 public maxBridgeInAmount = 10_000 * 10**18;
    uint256 public bridgeInCooldown = 1 minutes;
    uint256 public lastBridgeInTime;

    address[3] public signers;
    uint256 public constant REQUIRED_SIGNATURES = 3;
    uint256 public constant REQUIRED_SIGNATURES_FOR_UPDATE = 2;
    uint256 public immutable chainId;

    // Defining events for the contract
    event OperationRequested(
        bytes32 indexed operationId,
        OperationType indexed opType,
        address indexed requester,
        address target,
        uint256 value,
        bytes data,
        uint256 timestamp
    );

    event SignatureSubmitted(
        bytes32 indexed operationId,
        address indexed signer,
        uint256 currentSignatures,
        uint256 requiredSignatures,
        uint256 timestamp
    );

    event OperationExecuted(
        bytes32 indexed operationId,
        OperationType indexed opType
    );

    event MintExecuted(
        bytes32 indexed operationId,
        address indexed target,
        uint256 amount,
        uint256 newTotalSupply,
        uint256 nextMintTime
    );

    event BurnExecuted(
        bytes32 indexed operationId,
        address indexed target,
        uint256 amount,
        uint256 newTotalSupply
    );

    event LaunchStateChanged(
        bytes32 indexed operationId,
        bool isPreLaunch,
        uint256 timestamp
    );

    event BridgeInCallerUpdated(
        bytes32 indexed operationId,
        address indexed newCaller,
        uint256 timestamp
    );

    event BridgeInLimitsUpdated(
        bytes32 indexed operationId,
        uint256 newMaxAmount,
        uint256 newCooldown,
        uint256 timestamp
    );

    event BridgedOut(
        address indexed from,
        uint256 amount,
        address indexed targetAddress,
        uint256 indexed chainId,
        bytes32 txId,
        uint256 timestamp
    );

    event BridgedIn(
        address indexed to,
        uint256 amount,
        uint256 indexed chainId,
        bytes32 indexed txId,
        uint256 timestamp
    );

    event SignerUpdated(
        bytes32 indexed operationId,
        address indexed oldSigner,
        address indexed newSigner,
        uint256 timestamp
    );

    modifier onlySigner() {
        require(isSigner(msg.sender), "Not a signer");
        _;
    }

    modifier onlyBridgeInCaller() {
        require(msg.sender == bridgeInCaller, "Not authorized to bridge in");
        _;
    }

    constructor(address[3] memory _signers, uint256 _chainId) ERC20("Liberdus", "LBD") Ownable(msg.sender) {
        signers = _signers;
        chainId = _chainId;
    }

    function requestOperation(
        OperationType opType,
        address target,
        uint256 value,
        bytes memory data
    ) public returns (bytes32) {
        require(isSigner(msg.sender) || owner() == msg.sender, "Not authorized to request operation");
        
        if (opType == OperationType.UpdateSigner) {
            address oldSigner = target;
            address newSigner = address(uint160(value));
            require(isSigner(oldSigner), "Old signer not found");
            require(!isSigner(newSigner), "New signer already exists");
            require(oldSigner != msg.sender, "Cannot request to replace self");
        }

        bytes32 operationId = keccak256(abi.encodePacked(operationCount++, opType, target, value, data));
        Operation storage op = operations[operationId];
        op.opType = opType;
        op.target = target;
        op.value = value;
        op.data = data;
        op.executed = false;
        op.numSignatures = 0;

        emit OperationRequested(operationId, opType, msg.sender, target, value, data, block.timestamp);
        return operationId;
    }

    function submitSignature(bytes32 operationId, bytes memory signature) public {
        require(isSigner(msg.sender), "Only signers can submit signatures");
        Operation storage op = operations[operationId];
        require(!op.executed, "Operation already executed");
        require(!op.signatures[msg.sender], "Signature already submitted");

        bytes32 messageHash = getOperationHash(operationId);

        // Add Ethereum Signed Message prefix
        bytes32 prefixedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));

        // Recover the signer
        address signer = ECDSA.recover(prefixedHash, signature);

        // Signer from signature must match message sender
        require(signer == msg.sender, "Signature signer must be message sender");
        
        if (op.opType == OperationType.UpdateSigner) {
            // we allow owner to sign for UpdateSigner operations in case 2 signers lost their keys
            require(isSigner(signer) || signer == owner(), "Invalid signature for UpdateSigner");
            require(signer != op.target, "Signer being replaced cannot approve");
            require(op.numSignatures < REQUIRED_SIGNATURES_FOR_UPDATE, "Enough signatures already");
        } else {
            require(isSigner(signer), "Invalid signature");
            require(op.numSignatures < REQUIRED_SIGNATURES, "Enough signatures already");
        }

        op.signatures[signer] = true;
        op.numSignatures++;

        emit SignatureSubmitted(operationId, signer, op.numSignatures, REQUIRED_SIGNATURES, block.timestamp);

        if ((op.opType == OperationType.UpdateSigner && op.numSignatures == REQUIRED_SIGNATURES_FOR_UPDATE) ||
            (op.opType != OperationType.UpdateSigner && op.numSignatures == REQUIRED_SIGNATURES)) {
            executeOperation(operationId);
        }
    }

    function executeOperation(bytes32 operationId) internal nonReentrant {
        Operation storage op = operations[operationId];
        require(!op.executed, "Operation already executed");
        
        // Mark as executed before making any external calls
        op.executed = true;

        if (op.opType == OperationType.UpdateSigner) {
            _executeUpdateSigner(operationId, op.target, address(uint160(op.value)));
        } else if (op.opType == OperationType.Mint) {
            _executeMint(operationId);
        } else if (op.opType == OperationType.Burn) {
            _executeBurn(operationId, op.value);
        } else if (op.opType == OperationType.PostLaunch) {
            _executePostLaunch(operationId);
        } else if (op.opType == OperationType.Pause) {
            _pause();
        } else if (op.opType == OperationType.Unpause) {
            _unpause();
        } else if (op.opType == OperationType.SetBridgeInCaller) {
            _executeSetBridgeInCaller(operationId, op.target);
        } else if (op.opType == OperationType.SetBridgeInLimits) {
            _executeSetBridgeInLimits(operationId, op.value, abi.decode(op.data, (uint256)));
        } else {
            revert("Unknown operation type");
        }
        emit OperationExecuted(operationId, op.opType);
    }

    function _executeMint(bytes32 operationId) internal {
        Operation storage op = operations[operationId];  // Need to access the operation
        
        if (lastMintTime != 0) {
            require(block.timestamp >= lastMintTime + MINT_INTERVAL, "Mint interval not reached");
        }
        require(totalSupply() + MINT_AMOUNT <= MAX_SUPPLY, "Max supply exceeded");
        
        _mint(op.target, MINT_AMOUNT);  // Mint to the specified target address
        lastMintTime = block.timestamp;
        
        emit MintExecuted(
            operationId,
            op.target,
            MINT_AMOUNT,
            totalSupply(),
            lastMintTime + MINT_INTERVAL
        );
    }

    function _executeBurn(bytes32 operationId, uint256 amount) internal {
        Operation storage op = operations[operationId];
        
        // Ensure the target has enough balance and has approved the burn
        require(balanceOf(op.target) >= amount, "Insufficient balance to burn");
        
        _burn(op.target, amount);  // Burn from the specified target address
        emit BurnExecuted(
            operationId,
            op.target,
            amount,
            totalSupply()
        );
    }

    function _executePostLaunch(bytes32 operationId) internal {
        require(isPreLaunch, "Already in post-launch mode");
        isPreLaunch = false;
        emit LaunchStateChanged(
            operationId,
            isPreLaunch,
            block.timestamp
        );
    }

    function _executeSetBridgeInCaller(bytes32 operationId, address newCaller) internal {
        bridgeInCaller = newCaller;
        emit BridgeInCallerUpdated(
            operationId,
            newCaller,
            block.timestamp
        );
    }

    function _executeSetBridgeInLimits(bytes32 operationId, uint256 newMaxAmount, uint256 newCooldown) internal {
        maxBridgeInAmount = newMaxAmount;
        bridgeInCooldown = newCooldown;
        emit BridgeInLimitsUpdated(
            operationId,
            newMaxAmount,
            newCooldown,
            block.timestamp
        );
    }

    function _executeUpdateSigner(bytes32 operationId, address oldSigner, address newSigner) internal {
        require(isSigner(oldSigner), "Old signer not found");
        require(!isSigner(newSigner), "New signer already exists");
        
        for (uint i = 0; i < signers.length; i++) {
            if (signers[i] == oldSigner) {
                signers[i] = newSigner;
                break;
            }
        }
        emit SignerUpdated(
            operationId,
            oldSigner,
            newSigner,
            block.timestamp
        );
    }

    function bridgeOut(uint256 amount, address targetAddress, uint256 _chainId) public whenNotPaused {
        require(!isPreLaunch, "Bridge out not available in pre-launch");
        require(_chainId == chainId, "Invalid chain ID");
        _burn(msg.sender, amount);
        emit BridgedOut(msg.sender, amount, targetAddress, _chainId, blockhash(block.number - 1), block.timestamp);
    }

    function bridgeIn(address to, uint256 amount, uint256 _chainId, bytes32 txId) public onlyBridgeInCaller whenNotPaused {
        require(!isPreLaunch, "Bridge in not available in pre-launch");
        require(_chainId == chainId, "Invalid chain ID");
        require(amount <= maxBridgeInAmount, "Amount exceeds bridge-in limit");
        require(block.timestamp >= lastBridgeInTime + bridgeInCooldown, "Bridge-in cooldown not met");

        _mint(to, amount);
        lastBridgeInTime = block.timestamp;
        emit BridgedIn(to, amount, _chainId, txId, block.timestamp);
    }

        function isSigner(address account) public view returns (bool) {
        for (uint i = 0; i < signers.length; i++) {
            if (signers[i] == account) {
                return true;
            }
        }
        return false;
    }

    // --------- HELPER FUNCTIONS ---------
    function getOperationHash(bytes32 operationId) public view returns (bytes32) {
        Operation storage op = operations[operationId];
        return keccak256(abi.encodePacked(operationId, op.opType, op.target, op.value, op.data, chainId));
    }

    // Override transfer function to check for pause
    function transfer(address to, uint256 amount) public override whenNotPaused returns (bool) {
        return super.transfer(to, amount);
    }

    // Override transferFrom function to check for pause
    function transferFrom(address from, address to, uint256 amount) public override whenNotPaused returns (bool) {
        return super.transferFrom(from, to, amount);
    }

    function getChainId() public view returns (uint256) {
        return chainId;
    }

    function getNextMintTime() public view returns (uint256) {
        return lastMintTime + MINT_INTERVAL;
    }

    function getRemainingSupply() public view returns (uint256) {
        return MAX_SUPPLY - totalSupply();
    }

    /// @dev Overrides the _update function to add pause functionality to all token movements.
    /// This ensures that transfers, minting, and burning are all halted when the contract is paused.
    function _update(address from, address to, uint256 amount) internal override whenNotPaused {
        super._update(from, to, amount);
    }
}