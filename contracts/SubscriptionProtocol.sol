// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title SubscriptionProtocol
 * @notice On-chain recurring payment protocol for agent-to-agent subscriptions
 * @dev Enables pull-based recurring USDC payments with grace periods, 
 *      cancellation, and multi-tier plans
 * 
 * Flow:
 * 1. Provider creates a Plan (price, interval, features)
 * 2. Subscriber subscribes (approves USDC, first payment pulled)
 * 3. Provider/Keeper calls charge() when payment is due
 * 4. Subscriber can cancel anytime (active until period ends)
 */
contract SubscriptionProtocol is ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════════
    // STRUCTS
    // ═══════════════════════════════════════════════════════════════════════════

    struct Plan {
        address provider;           // Who receives payments
        uint256 price;              // Price per period (in token decimals)
        uint256 interval;           // Seconds between payments
        uint256 gracePeriod;        // Extra seconds before subscription lapses
        string name;                // Plan name (e.g., "Pro", "Enterprise")
        string metadata;            // IPFS hash or JSON for features
        bool active;                // Can new subscribers join?
        uint256 subscriberCount;    // Total active subscribers
    }

    struct Subscription {
        uint256 planId;             // Which plan
        address subscriber;         // Who pays
        uint256 startTime;          // When subscription started
        uint256 lastPayment;        // Timestamp of last successful payment
        uint256 nextPayment;        // When next payment is due
        bool active;                // Is subscription active?
        bool cancelled;             // Has subscriber cancelled? (stays active until period ends)
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════════

    IERC20 public immutable token;  // Payment token (USDC)
    
    uint256 public planCount;
    uint256 public subscriptionCount;
    uint256 public protocolFeeBps;  // Protocol fee in basis points (e.g., 100 = 1%)
    address public feeRecipient;
    
    mapping(uint256 => Plan) public plans;
    mapping(uint256 => Subscription) public subscriptions;
    
    // provider => planIds[]
    mapping(address => uint256[]) public providerPlans;
    
    // subscriber => subscriptionIds[]
    mapping(address => uint256[]) public subscriberSubs;
    
    // subscriber => planId => subscriptionId (0 if none)
    mapping(address => mapping(uint256 => uint256)) public activeSubscription;

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    event PlanCreated(uint256 indexed planId, address indexed provider, string name, uint256 price, uint256 interval);
    event PlanUpdated(uint256 indexed planId, uint256 price, bool active);
    event Subscribed(uint256 indexed subscriptionId, uint256 indexed planId, address indexed subscriber, uint256 firstPayment);
    event PaymentCharged(uint256 indexed subscriptionId, address indexed subscriber, address indexed provider, uint256 amount, uint256 fee);
    event SubscriptionCancelled(uint256 indexed subscriptionId, address indexed subscriber, uint256 activeUntil);
    event SubscriptionLapsed(uint256 indexed subscriptionId, address indexed subscriber, string reason);
    event SubscriptionReactivated(uint256 indexed subscriptionId, address indexed subscriber);

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error PlanNotFound();
    error PlanNotActive();
    error SubscriptionNotFound();
    error SubscriptionNotActive();
    error AlreadySubscribed();
    error NotSubscriber();
    error NotProvider();
    error PaymentNotDue();
    error PaymentFailed();
    error InvalidInterval();
    error InvalidPrice();
    error StillInGracePeriod();

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor(address _token, uint256 _protocolFeeBps, address _feeRecipient) {
        token = IERC20(_token);
        protocolFeeBps = _protocolFeeBps;
        feeRecipient = _feeRecipient;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PLAN MANAGEMENT (Provider)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Create a new subscription plan
     * @param price Amount in tokens per interval
     * @param interval Seconds between payments (e.g., 30 days = 2592000)
     * @param gracePeriod Extra seconds before lapse (e.g., 3 days = 259200)
     * @param name Human-readable plan name
     * @param metadata IPFS hash or JSON string with plan details
     */
    function createPlan(
        uint256 price,
        uint256 interval,
        uint256 gracePeriod,
        string calldata name,
        string calldata metadata
    ) external returns (uint256 planId) {
        if (price == 0) revert InvalidPrice();
        if (interval < 1 hours) revert InvalidInterval(); // Min 1 hour interval
        
        planId = ++planCount;
        
        plans[planId] = Plan({
            provider: msg.sender,
            price: price,
            interval: interval,
            gracePeriod: gracePeriod,
            name: name,
            metadata: metadata,
            active: true,
            subscriberCount: 0
        });
        
        providerPlans[msg.sender].push(planId);
        
        emit PlanCreated(planId, msg.sender, name, price, interval);
    }

    /**
     * @notice Update plan price or active status
     * @dev Only affects new subscriptions, existing ones keep old price until renewal
     */
    function updatePlan(uint256 planId, uint256 newPrice, bool active) external {
        Plan storage plan = plans[planId];
        if (plan.provider != msg.sender) revert NotProvider();
        
        plan.price = newPrice;
        plan.active = active;
        
        emit PlanUpdated(planId, newPrice, active);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SUBSCRIPTION MANAGEMENT (Subscriber)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Subscribe to a plan (pulls first payment immediately)
     * @dev Subscriber must have approved this contract for token spending
     * @param planId The plan to subscribe to
     */
    function subscribe(uint256 planId) external nonReentrant whenNotPaused returns (uint256 subscriptionId) {
        Plan storage plan = plans[planId];
        if (plan.provider == address(0)) revert PlanNotFound();
        if (!plan.active) revert PlanNotActive();
        if (activeSubscription[msg.sender][planId] != 0) revert AlreadySubscribed();
        
        subscriptionId = ++subscriptionCount;
        
        subscriptions[subscriptionId] = Subscription({
            planId: planId,
            subscriber: msg.sender,
            startTime: block.timestamp,
            lastPayment: block.timestamp,
            nextPayment: block.timestamp + plan.interval,
            active: true,
            cancelled: false
        });
        
        subscriberSubs[msg.sender].push(subscriptionId);
        activeSubscription[msg.sender][planId] = subscriptionId;
        plan.subscriberCount++;
        
        // Pull first payment
        _processPayment(subscriptionId, plan);
        
        emit Subscribed(subscriptionId, planId, msg.sender, plan.price);
    }

    /**
     * @notice Cancel subscription (remains active until current period ends)
     */
    function cancel(uint256 subscriptionId) external {
        Subscription storage sub = subscriptions[subscriptionId];
        if (sub.subscriber != msg.sender) revert NotSubscriber();
        if (!sub.active) revert SubscriptionNotActive();
        
        sub.cancelled = true;
        
        emit SubscriptionCancelled(subscriptionId, msg.sender, sub.nextPayment);
    }

    /**
     * @notice Reactivate a cancelled subscription before it lapses
     */
    function reactivate(uint256 subscriptionId) external {
        Subscription storage sub = subscriptions[subscriptionId];
        if (sub.subscriber != msg.sender) revert NotSubscriber();
        if (!sub.active) revert SubscriptionNotActive();
        
        sub.cancelled = false;
        
        emit SubscriptionReactivated(subscriptionId, msg.sender);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PAYMENT PROCESSING
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Charge a subscription (called by provider, keeper, or anyone)
     * @dev Can only charge when payment is due. Handles grace period and lapsing.
     */
    function charge(uint256 subscriptionId) external nonReentrant whenNotPaused {
        Subscription storage sub = subscriptions[subscriptionId];
        if (!sub.active) revert SubscriptionNotActive();
        
        Plan storage plan = plans[sub.planId];
        
        // Check if payment is due
        if (block.timestamp < sub.nextPayment) revert PaymentNotDue();
        
        // If cancelled and period ended, lapse the subscription
        if (sub.cancelled) {
            _lapse(subscriptionId, sub, plan, "Cancelled by subscriber");
            return;
        }
        
        // Check if past grace period
        if (block.timestamp > sub.nextPayment + plan.gracePeriod) {
            _lapse(subscriptionId, sub, plan, "Grace period expired");
            return;
        }
        
        // Try to process payment
        bool success = _tryProcessPayment(subscriptionId, plan);
        
        if (!success) {
            // If still in grace period, don't lapse yet
            if (block.timestamp <= sub.nextPayment + plan.gracePeriod) {
                revert PaymentFailed();
            }
            _lapse(subscriptionId, sub, plan, "Payment failed");
        }
    }

    /**
     * @notice Batch charge multiple subscriptions (for keepers)
     */
    function batchCharge(uint256[] calldata subscriptionIds) external nonReentrant whenNotPaused {
        for (uint256 i = 0; i < subscriptionIds.length; i++) {
            try this.charge(subscriptionIds[i]) {} catch {}
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL
    // ═══════════════════════════════════════════════════════════════════════════

    function _processPayment(uint256 subscriptionId, Plan storage plan) internal {
        Subscription storage sub = subscriptions[subscriptionId];
        
        uint256 fee = (plan.price * protocolFeeBps) / 10000;
        uint256 providerAmount = plan.price - fee;
        
        // Pull from subscriber
        token.safeTransferFrom(sub.subscriber, plan.provider, providerAmount);
        if (fee > 0) {
            token.safeTransferFrom(sub.subscriber, feeRecipient, fee);
        }
        
        sub.lastPayment = block.timestamp;
        sub.nextPayment = block.timestamp + plan.interval;
        
        emit PaymentCharged(subscriptionId, sub.subscriber, plan.provider, plan.price, fee);
    }

    function _tryProcessPayment(uint256 subscriptionId, Plan storage plan) internal returns (bool) {
        Subscription storage sub = subscriptions[subscriptionId];
        
        uint256 fee = (plan.price * protocolFeeBps) / 10000;
        uint256 providerAmount = plan.price - fee;
        
        // Check allowance and balance
        if (token.allowance(sub.subscriber, address(this)) < plan.price) return false;
        if (token.balanceOf(sub.subscriber) < plan.price) return false;
        
        // Pull from subscriber
        token.safeTransferFrom(sub.subscriber, plan.provider, providerAmount);
        if (fee > 0) {
            token.safeTransferFrom(sub.subscriber, feeRecipient, fee);
        }
        
        sub.lastPayment = block.timestamp;
        sub.nextPayment = block.timestamp + plan.interval;
        
        emit PaymentCharged(subscriptionId, sub.subscriber, plan.provider, plan.price, fee);
        return true;
    }

    function _lapse(uint256 subscriptionId, Subscription storage sub, Plan storage plan, string memory reason) internal {
        sub.active = false;
        plan.subscriberCount--;
        activeSubscription[sub.subscriber][sub.planId] = 0;
        
        emit SubscriptionLapsed(subscriptionId, sub.subscriber, reason);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Check if a subscription payment is due
     */
    function isPaymentDue(uint256 subscriptionId) external view returns (bool) {
        Subscription storage sub = subscriptions[subscriptionId];
        return sub.active && block.timestamp >= sub.nextPayment;
    }

    /**
     * @notice Check if subscription is in grace period
     */
    function isInGracePeriod(uint256 subscriptionId) external view returns (bool) {
        Subscription storage sub = subscriptions[subscriptionId];
        Plan storage plan = plans[sub.planId];
        return sub.active && 
               block.timestamp >= sub.nextPayment && 
               block.timestamp <= sub.nextPayment + plan.gracePeriod;
    }

    /**
     * @notice Get seconds until next payment is due
     */
    function timeUntilPayment(uint256 subscriptionId) external view returns (uint256) {
        Subscription storage sub = subscriptions[subscriptionId];
        if (block.timestamp >= sub.nextPayment) return 0;
        return sub.nextPayment - block.timestamp;
    }

    /**
     * @notice Get all plans by a provider
     */
    function getPlansByProvider(address provider) external view returns (uint256[] memory) {
        return providerPlans[provider];
    }

    /**
     * @notice Get all subscriptions by a subscriber
     */
    function getSubscriptionsBySubscriber(address subscriber) external view returns (uint256[] memory) {
        return subscriberSubs[subscriber];
    }

    /**
     * @notice Get detailed subscription status
     */
    function getSubscriptionStatus(uint256 subscriptionId) external view returns (
        bool active,
        bool cancelled,
        bool paymentDue,
        bool inGracePeriod,
        uint256 nextPaymentTime,
        uint256 amountDue
    ) {
        Subscription storage sub = subscriptions[subscriptionId];
        Plan storage plan = plans[sub.planId];
        
        active = sub.active;
        cancelled = sub.cancelled;
        paymentDue = sub.active && block.timestamp >= sub.nextPayment;
        inGracePeriod = sub.active && 
                        block.timestamp >= sub.nextPayment && 
                        block.timestamp <= sub.nextPayment + plan.gracePeriod;
        nextPaymentTime = sub.nextPayment;
        amountDue = plan.price;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN
    // ═══════════════════════════════════════════════════════════════════════════

    function setProtocolFee(uint256 newFeeBps) external {
        require(msg.sender == feeRecipient, "Not fee recipient");
        require(newFeeBps <= 1000, "Fee too high"); // Max 10%
        protocolFeeBps = newFeeBps;
    }

    function pause() external {
        require(msg.sender == feeRecipient, "Not admin");
        _pause();
    }

    function unpause() external {
        require(msg.sender == feeRecipient, "Not admin");
        _unpause();
    }
}
