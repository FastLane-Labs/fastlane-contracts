# Task Manager Integration Guide

This guide explains how to integrate with the Task Manager system, covering encoding patterns, advanced features, and best practices.

## Task Encoding Pattern

Tasks must use a 3-layer encoding pattern:
1. Encode the actual function call to your target contract.
2. Pack the target address and calldata together.
3. Encode the call to the execution environment's function (e.g., `executeTask`).

Example:
```solidity
// 1. Encode the actual function call to your target contract
bytes memory functionCall = abi.encodeWithSelector(
    MyContract.myFunction.selector,
    param1,
    param2
);

// 2. Pack target address and calldata together
bytes memory packedData = abi.encode(
    targetContractAddress,
    functionCall
);

// 3. Encode the call to the execution environment's function
bytes memory taskData = abi.encodeWithSelector(
    ITaskExecutionEnvironment.executeTask.selector,
    packedData
);

// Finally, schedule the task with the fully encoded data
taskManager.scheduleTask(
    implementationAddress,  // Execution environment address
    100_000,                // Gas limit
    block.number + 10,      // Target block
    maxPayment,             // Maximum payment
    taskData                // Encoded task data with all 3 layers
);
```

Note that different execution environments may require specific encoding patterns or additional parameters. Always refer to the specific environment's documentation for exact encoding requirements.

# Task Manager Advanced Features & Examples

This section contains detailed documentation and example implementations for advanced Task Manager features. While the root README covers basic usage, here we explore:

- Custom execution environments
- Advanced task management
- Security and authorization patterns
- Economic models and fee handling

## Available Environments

### ReschedulingTaskEnvironment

Location: `ReschedulingTaskEnvironment.sol`

A task environment that implements automatic retry logic for failed tasks. Features:

- Maximum of 3 retry attempts
- 5 block delay between retries
- Event emission for execution tracking
- Built-in input validation

Usage example:
```solidity
// Deploy the environment
ReschedulingTaskEnvironment env = new ReschedulingTaskEnvironment(taskManagerAddress);

// Schedule a task using this environment
taskManager.scheduleTask(
    address(env),    // Use the rescheduling environment
    100_000,        // Gas limit
    targetBlock,    // Target block
    maxPayment,     // Max payment
    taskData        // Encoded task data
);
```

Events emitted:
- `TaskStarted(address target, bytes data)`
- `TaskCompleted(address target, bool success)`
- `TaskRescheduled(address target, uint64 newTargetBlock)`
- `ExecutionAttempt(uint8 attemptNumber, bool success)`

### BasicTaskEnvironment

Location: `BasicTaskEnvironment.sol`

A helper environment that provides pre-execution validation and execution logging. Features:
- Input validation (non-zero address, non-empty calldata)
- Detailed event emission
- Error propagation from failed calls
- Task isolation

## Advanced Topics

### Rescheduling Tasks

The Task Manager supports task rescheduling using dedicated execution environments (such as the **ReschedulingTaskEnvironment**). This feature improves reliability without requiring manual intervention.

#### How Rescheduling Works

- **Automatic Retry:** When a task fails, the environment emits an event and schedules a retry after a defined delay
- **Retry Limit:** A maximum number of retries (e.g., `MAX_RETRIES = 3`) prevents infinite retry loops

### Task Cancellation and Authorization

The Task Manager provides flexible authorization mechanisms that allow task owners to delegate control over their tasks:

#### Task-Level Authorization

Individual tasks can have multiple authorized cancellers:

```solidity
// As the task owner
function setupTaskCanceller(bytes32 taskId, address canceller) external {
    // Add authorization for a specific task
    taskManager.addTaskCanceller(taskId, canceller);
}

// As the authorized canceller
function cancelSpecificTask(bytes32 taskId) external {
    // This will only succeed if msg.sender is an authorized canceller
    taskManager.cancelTask(taskId);
}

// As the task owner, remove authorization
function removeTaskCanceller(bytes32 taskId, address canceller) external {
    taskManager.removeTaskCanceller(taskId, canceller);
}
```

#### Environment-Level Authorization

For more granular control, you can authorize cancellers at the environment level:

```solidity
// As the environment owner
function setupEnvironmentCanceller(bytes32 taskId, address canceller) external {
    // Add authorization for all tasks in this environment
    taskManager.addEnvironmentCanceller(taskId, canceller);
}

// As the authorized environment canceller
function cancelEnvironmentTask(bytes32 taskId) external {
    // This will succeed for any task in the authorized environment
    taskManager.cancelTask(taskId);
}

// As the environment owner, remove authorization
function removeEnvironmentCanceller(bytes32 taskId, address canceller) external {
    taskManager.removeEnvironmentCanceller(taskId, canceller);
}
```

#### Authorization Hierarchy

The system implements a hierarchical authorization model:
1. Task Owner: Has full control over the task
2. Environment Cancellers: Can cancel any task in their authorized environment
3. Task Cancellers: Can only cancel specific authorized tasks
4. Others: No cancellation rights

### Economic Security & Fee Calculations

The system employs a dynamic fee model for fair compensation and economic security through bonding.

#### Example: Estimating and Handling Fees

```solidity
// Estimate the cost of executing a task before scheduling
uint256 estimatedCost = taskManager.estimateCost(targetBlock, 100_000);
require(estimatedCost > 0, "Estimated cost must be positive");

// After task execution, fees are automatically distributed
uint256 feesEarned = taskManager.executeTasks(payoutAddress, 0);
require(feesEarned > 0, "Execution should earn fees");
```

## Execution Environment Architecture

### Overview

The Execution Environment (EE) is a critical security component that provides an airgapped execution context for tasks. This architecture ensures:

- Isolated execution of each task
- Controlled access to task execution
- Customizable execution logic
- Protection against unauthorized calls

### Security Model

The security of Execution Environments is enforced at two levels:

1. **Proxy-Level Enforcement** (Primary Security):
   - The Task Manager uses a specialized proxy pattern to interact with EEs
   - Only the `executeTask` function can be called through this proxy
   - All other function calls are blocked at the proxy level
   - This makes the `onlyTaskManager` modifier optional, as security is enforced by the proxy

```solidity
contract TaskExecutionBase {
    address public immutable TASK_MANAGER;
    
    // Note: This modifier is optional since proxy enforces the restriction
    modifier onlyTaskManager() {
        require(msg.sender == TASK_MANAGER, "Only TaskManager");
        _;
    }
}
```

2. **Environment-Level Controls** (Additional Safety):
   - EEs can implement additional security measures
   - Input validation
   - Custom access controls
   - Execution flow restrictions

Key security features:
1. **Airgapped Execution**: Tasks execute in isolated environments to prevent cross-task interference
2. **Proxy Protection**: The proxy pattern ensures only `executeTask` can be called, and only by the Task Manager
3. **Customizable Security**: Each EE can add its own security measures while maintaining core protections
4. **No State Dependencies**: EEs should be stateless between executions

### Minimal Secure Environment

Here's an example of a minimal secure environment that relies on proxy-level protection:

```solidity
contract MinimalExecutionEnvironment {

    function executeTask(bytes calldata taskData) external returns (bool) {
        (address target, bytes memory data) = abi.decode(taskData, (address, bytes));
        (bool success,) = target.call(data);
        return success;
    }
}
```

### Deployment Model

Anyone can deploy their own Execution Environment:

```solidity
// Deploy a custom environment
MyExecutionEnvironment myEE = new MyExecutionEnvironment(taskManagerAddress);

// Use it when scheduling tasks
taskManager.scheduleTask(
    address(myEE),  // Your custom environment
    gasLimit,
    targetBlock,
    maxPayment,
    taskData
);
```

### Best Practices

1. **Post-Execution Control**:
   - Instead of modifying the EE, implement control flow in your target contract
   - Example:
   ```solidity
   contract MyTarget {
       function executeWithPostChecks(uint256 value) external {
           // Perform the main task
           performTask(value);
           
           // Add post-execution logic here
           if (condition) {
               handleSuccess();
           } else {
               handleFailure();
           }
       }
   }
   ```

2. **Environment Selection**:
   - Use `BasicTaskEnvironment` for simple, direct execution (Fastlane flavored example)
   - Use `ReschedulingTaskEnvironment` for automatic retry logic (e.g. for failed transactions)
   - Create custom environments for specific requirements

3. **Security Considerations**:
   - EEs should not store state between executions
   - Validate all inputs in `executeTask`
   - Emit events for important state changes
   - Consider gas implications of custom logic

### Custom Environment Example

Here's an example of a custom environment with additional validation:

```solidity
contract ValidatedExecutionEnvironment is TaskExecutionBase {
    // Custom error types
    error InvalidTarget();
    error InvalidValue();
    
    // Events for tracking
    event TaskValidated(address target, uint256 value);
    
    constructor(address taskManager_) TaskExecutionBase(taskManager_) {}
    
    function executeTask(bytes calldata taskData) 
        external 
        onlyTaskManager 
        returns (bool)
    {
        // Decode with custom parameters
        (address target, bytes memory data) = abi.decode(taskData, (address, bytes));
        
        // Custom validation
        if (!isValidTarget(target)) revert InvalidTarget();
        if (!isValidValue(data)) revert InvalidValue();
        
        // Emit pre-execution event
        emit TaskValidated(target, abi.decode(data, (uint256)));
        
        // Execute with validated parameters
        (bool success,) = target.call(data);
        return success;
    }
    
    function isValidTarget(address target) internal view returns (bool) {
        // Add custom target validation
        return target != address(0) && target.code.length > 0;
    }
    
    function isValidValue(bytes memory data) internal pure returns (bool) {
        // Add custom data validation
        if (data.length < 4) return false; // At least need function selector
        return true;
    }
}
```

## Creating Custom Environments

To create your own execution environment:

1. Inherit from `TaskExecutionBase` (optional)
2. Implement the `executeTask` function (recommended but can be any function)
3. Add any custom logic for:
   - Pre/post execution hooks
   - Error handling
   - Event emission
   - State management

Example template:
```solidity
contract CustomTaskEnvironment is TaskExecutionBase {
    constructor(address taskManager_) TaskExecutionBase(taskManager_) {}

    function executeTask(bytes calldata taskData) 
        external 
        onlyTaskManager 
        returns (bool)
    {
        // 1. Decode task data
        (address target, bytes memory data) = abi.decode(taskData, (address, bytes));

        // 2. Add custom pre-execution logic
        
        // 3. Execute the task
        (bool success,) = target.call(data);
        
        // 4. Add custom post-execution logic
        
        return success;
    }
}
``` 