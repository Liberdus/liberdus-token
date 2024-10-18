// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract Liberdus is ERC20, Pausable {
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

    event OperationRequested(bytes32 indexed operationId, OperationType indexed opType);
    event SignatureSubmitted(bytes32 indexed operationId, address indexed signer);
    event OperationExecuted(bytes32 indexed operationId, OperationType indexed opType);
    event BridgedOut(address indexed from, uint256 amount, address indexed targetAddress, bytes32 txId);
    event BridgedIn(address indexed to, uint256 amount, bytes32 txId);

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

    constructor(address[3] memory _signers) ERC20("Liberdus Token", "LIB") {
        signers = _signers;
    }

    function isSigner(address account) public view returns (bool) {
        for (uint i = 0; i < signers.length; i++) {
            if (signers[i] == account) {
                return true;
            }
        }
        return false;
    }

    function requestOperation(
        OperationType opType,
        address target,
        uint256 value,
        bytes memory data
    ) public onlySigner returns (bytes32) {
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
        Operation storage op = operations[operationId];
        require(!op.executed, "Operation already executed");

        bytes32 messageHash = getOperationHash(operationId);
        emit DebugLog("Raw message hash", messageHash);

        // Add Ethereum Signed Message prefix
        bytes32 prefixedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        emit DebugLog("Prefixed hash", prefixedHash);

        // Recover the signer
        address signer = ECDSA.recover(prefixedHash, signature);
        emit DebugAddress("Recovered signer", signer);
        
        require(isSigner(signer), "Invalid signature");
        require(!op.signatures[signer], "Signature already submitted for this signer");

        op.signatures[signer] = true;
        op.numSignatures++;

        emit SignatureSubmitted(operationId, signer);

        if (op.numSignatures == REQUIRED_SIGNATURES) {
            executeOperation(operationId);
        }
    }

    function executeOperation(bytes32 operationId) internal {
        Operation storage op = operations[operationId];
        require(op.numSignatures == REQUIRED_SIGNATURES, "Not enough signatures");
        require(!op.executed, "Operation already executed");

        op.executed = true;

        if (op.opType == OperationType.Mint) {
            require(isPreLaunch, "Minting only allowed in pre-launch");
            _executeMint();
        } else if (op.opType == OperationType.Burn) {
            require(isPreLaunch, "Burning only allowed in pre-launch");
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
        } else if (op.opType == OperationType.UpdateSigner) {
            _executeUpdateSigner(op.target, address(uint160(op.value)));
        }

        emit OperationExecuted(operationId, op.opType);
    }

    function getOperationHash(bytes32 operationId) public view returns (bytes32) {
        Operation storage op = operations[operationId];
        return keccak256(abi.encodePacked(operationId, op.opType, op.target, op.value, op.data));
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

    function bridgeOut(uint256 amount, address targetAddress) public whenNotPaused {
        require(!isPreLaunch, "Bridge out not available in pre-launch");
        _burn(msg.sender, amount);
        emit BridgedOut(msg.sender, amount, targetAddress, blockhash(block.number - 1));
    }

    function bridgeIn(address to, uint256 amount, bytes32 txId) public onlyBridgeInCaller whenNotPaused {
        require(!isPreLaunch, "Bridge in not available in pre-launch");
        require(amount <= maxBridgeInAmount, "Amount exceeds bridge-in limit");
        require(block.timestamp >= lastBridgeInTime + bridgeInCooldown, "Bridge-in cooldown not met");

        lastBridgeInTime = block.timestamp;
        _mint(to, amount);
        emit BridgedIn(to, amount, txId);
    }

    function getNextMintTime() public view returns (uint256) {
        return lastMintTime + MINT_INTERVAL;
    }

    function getRemainingSupply() public view returns (uint256) {
        return MAX_SUPPLY - totalSupply();
    }

    function _update(address from, address to, uint256 amount) internal override whenNotPaused {
        super._update(from, to, amount);
    }
}