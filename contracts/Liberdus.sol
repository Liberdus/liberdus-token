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


    event OperationRequested(bytes32 indexed operationId, OperationType indexed opType);
    event SignatureSubmitted(bytes32 indexed operationId, address indexed signer);
    event OperationExecuted(bytes32 indexed operationId, OperationType indexed opType);
    event BridgedOut(address indexed from, uint256 amount, address indexed targetAddress, uint256 chainId, bytes32 txId);
    event BridgedIn(address indexed to, uint256 amount, uint256 chainId, bytes32 txId);

    event DebugLog(string message, bytes32 data);
    event DebugAddress(string message, address data);

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

        emit OperationRequested(operationId, opType);
        return operationId;
    }

    function submitSignature(bytes32 operationId, bytes memory signature) public {
        require(isSigner(msg.sender), "Only signers can submit signatures");
        Operation storage op = operations[operationId];
        require(!op.executed, "Operation already executed");
        require(!op.signatures[msg.sender], "Signature already submitted");

        bytes32 messageHash = getOperationHash(operationId);
        emit DebugLog("Raw message hash", messageHash);

        // Add Ethereum Signed Message prefix
        bytes32 prefixedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        emit DebugLog("Prefixed hash", prefixedHash);

        // Recover the signer
        address signer = ECDSA.recover(prefixedHash, signature);
        emit DebugAddress("Recovered signer", signer);
        
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

        emit SignatureSubmitted(operationId, signer);

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
            _executeUpdateSigner(op.target, address(uint160(op.value)));
        } else if (op.opType == OperationType.Mint) {
            _executeMint();
        } else if (op.opType == OperationType.Burn) {
            _executeBurn(op.value);
        } else if (op.opType == OperationType.PostLaunch) {
            _executePostLaunch();
        } else if (op.opType == OperationType.Pause) {
            _pause();
        } else if (op.opType == OperationType.Unpause) {
            _unpause();
        } else if (op.opType == OperationType.SetBridgeInCaller) {
            _executeSetBridgeInCaller(op.target);
        } else if (op.opType == OperationType.SetBridgeInLimits) {
            _executeSetBridgeInLimits(op.value, abi.decode(op.data, (uint256)));
        } else {
            revert("Unknown operation type");
        }

        emit OperationExecuted(operationId, op.opType);
    }

    function isSigner(address account) public view returns (bool) {
        for (uint i = 0; i < signers.length; i++) {
            if (signers[i] == account) {
                return true;
            }
        }
        return false;
    }

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

    function _executeMint() internal {
        if (lastMintTime != 0) {
            require(block.timestamp >= lastMintTime + MINT_INTERVAL, "Mint interval not reached");
        }
        require(totalSupply() + MINT_AMOUNT <= MAX_SUPPLY, "Max supply exceeded");
        
        lastMintTime = block.timestamp;
        _mint(msg.sender, MINT_AMOUNT);
    }

    function _executeBurn(uint256 amount) internal {
        _burn(msg.sender, amount);
    }

    function _executePostLaunch() internal {
        require(isPreLaunch, "Already in post-launch mode");
        isPreLaunch = false;
    }

    function _executeSetBridgeInCaller(address newCaller) internal {
        bridgeInCaller = newCaller;
    }

    function _executeSetBridgeInLimits(uint256 newMaxAmount, uint256 newCooldown) internal {
        maxBridgeInAmount = newMaxAmount;
        bridgeInCooldown = newCooldown;
    }

    function _executeUpdateSigner(address oldSigner, address newSigner) internal {
        require(isSigner(oldSigner), "Old signer not found");
        require(!isSigner(newSigner), "New signer already exists");
        
        for (uint i = 0; i < signers.length; i++) {
            if (signers[i] == oldSigner) {
                signers[i] = newSigner;
                break;
            }
        }
    }

    function bridgeOut(uint256 amount, address targetAddress, uint256 _chainId) public whenNotPaused {
        require(!isPreLaunch, "Bridge out not available in pre-launch");
        require(_chainId == chainId, "Invalid chain ID");
        _burn(msg.sender, amount);
        emit BridgedOut(msg.sender, amount, targetAddress, _chainId, blockhash(block.number - 1));
    }

    function bridgeIn(address to, uint256 amount, uint256 _chainId, bytes32 txId) public onlyBridgeInCaller whenNotPaused {
        require(!isPreLaunch, "Bridge in not available in pre-launch");
        require(_chainId == chainId, "Invalid chain ID");
        require(amount <= maxBridgeInAmount, "Amount exceeds bridge-in limit");
        require(block.timestamp >= lastBridgeInTime + bridgeInCooldown, "Bridge-in cooldown not met");

        lastBridgeInTime = block.timestamp;
        _mint(to, amount);
        emit BridgedIn(to, amount, _chainId, txId);
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