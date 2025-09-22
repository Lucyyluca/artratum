# Token Vesting Smart Contract

A Clarity smart contract for managing token vesting schedules with granular controls.

## Features

- **Grant Management**
  - Create vesting schedules with customizable parameters
  - Support for cliff periods and linear vesting
  - Grant revocation capability

- **Access Control**
  - Contract owner privileges
  - Recipient-specific withdrawals
  - Authorization checks

- **Vesting Mechanics**
  - Linear vesting calculation
  - Cliff period enforcement
  - Block height-based timing

## Core Functions

### Administrative
- `create-grant`: Create new vesting schedules
- `revoke-grant`: Revoke existing grants

### User Operations
- `withdraw`: Claim vested tokens
- `withdrawable`: Check available tokens
- `vested`: Calculate vested amount

### Query Functions
- `get-grant`: Retrieve grant details
- `get-grant-status`: Get comprehensive grant status

## Error Handling

Built-in error constants:
- `err-not-found (u1)`
- `err-unauthorized (u2)`
- `err-grant-revoked (u3)`
- `err-no-withdrawable (u4)`

## Data Structure

Grants are stored in a map with the following properties:
```clarity
{
  recipient: principal,
  total: uint,
  start-height: uint,
  cliff: uint,
  duration: uint,
  revoked: bool,
  withdrawn: uint
}
```
