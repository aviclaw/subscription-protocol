# Subscription Protocol 💳

On-chain recurring USDC payments for the agent economy. Enables pull-based subscriptions between AI agents with grace periods, cancellation, and multi-tier plans.

## The Problem

Recurring payments are hard on-chain:
- No native "pull" mechanism - users must push each payment
- No way to handle failed payments gracefully
- No standard for subscription lifecycle management

## The Solution

SubscriptionProtocol introduces proper recurring payments:
- **Pull-based**: Providers (or keepers) pull payments when due
- **Grace periods**: Subscribers get extra time if payment fails
- **Lifecycle management**: Subscribe → Charge → Cancel → Lapse
- **Multi-tier plans**: Providers can offer multiple subscription tiers

## How It Works

```
┌─────────────┐     ┌─────────────────────┐     ┌──────────────┐
│  Provider   │────▶│ SubscriptionProtocol│◀────│  Subscriber  │
│  (Agent B)  │     │                     │     │  (Agent A)   │
└─────────────┘     └─────────────────────┘     └──────────────┘
       │                      │                        │
       │ 1. createPlan()      │                        │
       │─────────────────────▶│                        │
       │                      │                        │
       │                      │    2. approve(USDC)    │
       │                      │◀───────────────────────│
       │                      │                        │
       │                      │    3. subscribe(planId)│
       │                      │◀───────────────────────│
       │                      │     [first payment]    │
       │◀─────────────────────│                        │
       │                      │                        │
       │ 4. charge() [monthly]│                        │
       │─────────────────────▶│                        │
       │                      │    [payment pulled]    │
       │◀─────────────────────│───────────────────────▶│
```

## Features

### For Providers (Service Sellers)
- Create subscription plans with custom pricing and intervals
- Set grace periods for payment flexibility
- Receive payments automatically when due
- Multiple plans (tiers) per provider

### For Subscribers (Service Buyers)
- Subscribe with one transaction
- Cancel anytime (service continues until period ends)
- Reactivate cancelled subscriptions
- Clear visibility into payment schedule

### Protocol Features
- **Grace Period**: Extra time before subscription lapses
- **Batch Charging**: Keepers can charge multiple subscriptions in one tx
- **Protocol Fee**: Optional fee on each payment (configurable)
- **Pause/Unpause**: Emergency stop capability

## Installation

```bash
npm install
npx hardhat compile
npx hardhat test
```

## Deployment

```bash
export DEPLOYER_PRIVATE_KEY=0x...
npx hardhat run scripts/deploy.js --network base-sepolia
```

## Usage

### Create a Plan (Provider)

```solidity
// 10 USDC per month, 3-day grace period
protocol.createPlan(
    10_000000,           // price: 10 USDC (6 decimals)
    30 * 24 * 60 * 60,   // interval: 30 days in seconds
    3 * 24 * 60 * 60,    // gracePeriod: 3 days
    "Pro Plan",          // name
    '{"api_calls": "unlimited"}' // metadata
);
```

### Subscribe (Subscriber)

```solidity
// First, approve USDC spending
USDC.approve(protocolAddress, type(uint256).max);

// Then subscribe (pulls first payment immediately)
protocol.subscribe(planId);
```

### Charge (Provider/Keeper)

```solidity
// Charge a single subscription
protocol.charge(subscriptionId);

// Batch charge multiple
protocol.batchCharge([subId1, subId2, subId3]);
```

### Cancel (Subscriber)

```solidity
// Cancel - stays active until current period ends
protocol.cancel(subscriptionId);

// Changed your mind? Reactivate before period ends
protocol.reactivate(subscriptionId);
```

## Subscription States

```
┌───────────┐  subscribe()   ┌────────┐  charge() fails   ┌─────────────┐
│  (none)   │───────────────▶│ ACTIVE │──────────────────▶│ GRACE_PERIOD│
└───────────┘                └────────┘                   └─────────────┘
                                  │                             │
                            cancel()                    grace expires
                                  │                             │
                                  ▼                             ▼
                            ┌──────────┐                  ┌─────────┐
                            │CANCELLED │─────────────────▶│ LAPSED  │
                            │(active)  │  period ends     │(inactive)│
                            └──────────┘                  └─────────┘
```

## Contract Interface

```solidity
// Plan management (Provider)
function createPlan(uint256 price, uint256 interval, uint256 gracePeriod, string name, string metadata) returns (uint256 planId)
function updatePlan(uint256 planId, uint256 newPrice, bool active)

// Subscription management (Subscriber)
function subscribe(uint256 planId) returns (uint256 subscriptionId)
function cancel(uint256 subscriptionId)
function reactivate(uint256 subscriptionId)

// Payment (Anyone - typically Provider or Keeper)
function charge(uint256 subscriptionId)
function batchCharge(uint256[] subscriptionIds)

// View functions
function isPaymentDue(uint256 subscriptionId) returns (bool)
function isInGracePeriod(uint256 subscriptionId) returns (bool)
function timeUntilPayment(uint256 subscriptionId) returns (uint256)
function getSubscriptionStatus(uint256 subscriptionId) returns (...)
```

## Use Cases

1. **Agent API Services**: Agent B provides an API, Agent A subscribes for monthly access
2. **Data Feeds**: Real-time data subscriptions between agents
3. **Compute Services**: Pay-per-month GPU/compute access
4. **Content Access**: Premium content subscriptions for AI agents
5. **Monitoring Services**: Ongoing wallet/contract monitoring

## Security

- Uses OpenZeppelin's SafeERC20 and ReentrancyGuard
- No admin can drain user funds
- Grace periods protect against temporary payment failures
- Pause functionality for emergencies

## License

MIT
