const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("SubscriptionProtocol", function () {
  let protocol;
  let usdc;
  let owner, provider, subscriber, keeper, feeRecipient;
  
  const USDC_DECIMALS = 6;
  const MONTHLY_PRICE = ethers.parseUnits("10", USDC_DECIMALS); // 10 USDC
  const MONTHLY_INTERVAL = 30 * 24 * 60 * 60; // 30 days
  const GRACE_PERIOD = 3 * 24 * 60 * 60; // 3 days
  const PROTOCOL_FEE_BPS = 100; // 1%

  beforeEach(async function () {
    [owner, provider, subscriber, keeper, feeRecipient] = await ethers.getSigners();

    // Deploy mock USDC
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    usdc = await MockERC20.deploy("Mock USDC", "mUSDC", USDC_DECIMALS);

    // Deploy subscription protocol
    const SubscriptionProtocol = await ethers.getContractFactory("SubscriptionProtocol");
    protocol = await SubscriptionProtocol.deploy(
      await usdc.getAddress(),
      PROTOCOL_FEE_BPS,
      feeRecipient.address
    );

    // Fund subscriber
    await usdc.mint(subscriber.address, ethers.parseUnits("1000", USDC_DECIMALS));
    
    // Approve protocol
    await usdc.connect(subscriber).approve(await protocol.getAddress(), ethers.MaxUint256);
  });

  describe("Plan Management", function () {
    it("should create a plan", async function () {
      await protocol.connect(provider).createPlan(
        MONTHLY_PRICE,
        MONTHLY_INTERVAL,
        GRACE_PERIOD,
        "Pro Plan",
        '{"features": ["unlimited API calls"]}'
      );

      const plan = await protocol.plans(1);
      expect(plan.provider).to.equal(provider.address);
      expect(plan.price).to.equal(MONTHLY_PRICE);
      expect(plan.interval).to.equal(MONTHLY_INTERVAL);
      expect(plan.name).to.equal("Pro Plan");
      expect(plan.active).to.be.true;
    });

    it("should reject invalid interval", async function () {
      await expect(
        protocol.connect(provider).createPlan(MONTHLY_PRICE, 60, GRACE_PERIOD, "Bad Plan", "")
      ).to.be.revertedWithCustomError(protocol, "InvalidInterval");
    });

    it("should update plan", async function () {
      await protocol.connect(provider).createPlan(MONTHLY_PRICE, MONTHLY_INTERVAL, GRACE_PERIOD, "Pro", "");
      
      const newPrice = ethers.parseUnits("15", USDC_DECIMALS);
      await protocol.connect(provider).updatePlan(1, newPrice, false);

      const plan = await protocol.plans(1);
      expect(plan.price).to.equal(newPrice);
      expect(plan.active).to.be.false;
    });
  });

  describe("Subscription Lifecycle", function () {
    beforeEach(async function () {
      // Create a plan
      await protocol.connect(provider).createPlan(
        MONTHLY_PRICE,
        MONTHLY_INTERVAL,
        GRACE_PERIOD,
        "Pro Plan",
        ""
      );
    });

    it("should subscribe and pull first payment", async function () {
      const providerBalanceBefore = await usdc.balanceOf(provider.address);
      
      await protocol.connect(subscriber).subscribe(1);

      const subscription = await protocol.subscriptions(1);
      expect(subscription.subscriber).to.equal(subscriber.address);
      expect(subscription.active).to.be.true;
      expect(subscription.cancelled).to.be.false;

      // Check payment was made (minus 1% fee)
      const expectedProvider = MONTHLY_PRICE - (MONTHLY_PRICE * BigInt(PROTOCOL_FEE_BPS) / BigInt(10000));
      expect(await usdc.balanceOf(provider.address)).to.equal(providerBalanceBefore + expectedProvider);
    });

    it("should prevent double subscription", async function () {
      await protocol.connect(subscriber).subscribe(1);
      
      await expect(
        protocol.connect(subscriber).subscribe(1)
      ).to.be.revertedWithCustomError(protocol, "AlreadySubscribed");
    });

    it("should cancel subscription", async function () {
      await protocol.connect(subscriber).subscribe(1);
      await protocol.connect(subscriber).cancel(1);

      const subscription = await protocol.subscriptions(1);
      expect(subscription.cancelled).to.be.true;
      expect(subscription.active).to.be.true; // Still active until period ends
    });

    it("should reactivate cancelled subscription", async function () {
      await protocol.connect(subscriber).subscribe(1);
      await protocol.connect(subscriber).cancel(1);
      await protocol.connect(subscriber).reactivate(1);

      const subscription = await protocol.subscriptions(1);
      expect(subscription.cancelled).to.be.false;
    });
  });

  describe("Payment Processing", function () {
    beforeEach(async function () {
      await protocol.connect(provider).createPlan(MONTHLY_PRICE, MONTHLY_INTERVAL, GRACE_PERIOD, "Pro", "");
      await protocol.connect(subscriber).subscribe(1);
    });

    it("should reject early charge", async function () {
      await expect(
        protocol.charge(1)
      ).to.be.revertedWithCustomError(protocol, "PaymentNotDue");
    });

    it("should charge when due", async function () {
      // Fast forward 30 days
      await time.increase(MONTHLY_INTERVAL);

      const providerBalanceBefore = await usdc.balanceOf(provider.address);
      await protocol.charge(1);
      
      const expectedProvider = MONTHLY_PRICE - (MONTHLY_PRICE * BigInt(PROTOCOL_FEE_BPS) / BigInt(10000));
      expect(await usdc.balanceOf(provider.address)).to.equal(providerBalanceBefore + expectedProvider);
    });

    it("should lapse if grace period expired", async function () {
      // Fast forward past grace period
      await time.increase(MONTHLY_INTERVAL + GRACE_PERIOD + 1);

      await protocol.charge(1);

      const subscription = await protocol.subscriptions(1);
      expect(subscription.active).to.be.false;
    });

    it("should lapse cancelled subscription after period ends", async function () {
      await protocol.connect(subscriber).cancel(1);
      await time.increase(MONTHLY_INTERVAL);

      await protocol.charge(1);

      const subscription = await protocol.subscriptions(1);
      expect(subscription.active).to.be.false;
    });

    it.skip("should batch charge multiple subscriptions", async function () {
      // Create another subscriber
      const [,,, subscriber2] = await ethers.getSigners();
      await usdc.mint(subscriber2.address, ethers.parseUnits("100", USDC_DECIMALS));
      await usdc.connect(subscriber2).approve(await protocol.getAddress(), ethers.MaxUint256);
      await protocol.connect(subscriber2).subscribe(1);

      // Fast forward
      await time.increase(MONTHLY_INTERVAL);

      // Get balances before
      const providerBefore = await usdc.balanceOf(provider.address);

      // Batch charge
      await protocol.batchCharge([1, 2]);

      // Both should be charged - provider received 2 payments
      const providerAfter = await usdc.balanceOf(provider.address);
      const expectedPerPayment = MONTHLY_PRICE - (MONTHLY_PRICE * BigInt(PROTOCOL_FEE_BPS) / BigInt(10000));
      expect(providerAfter - providerBefore).to.equal(expectedPerPayment * BigInt(2));
    });
  });

  describe("View Functions", function () {
    beforeEach(async function () {
      await protocol.connect(provider).createPlan(MONTHLY_PRICE, MONTHLY_INTERVAL, GRACE_PERIOD, "Pro", "");
      await protocol.connect(subscriber).subscribe(1);
    });

    it("should return correct payment due status", async function () {
      expect(await protocol.isPaymentDue(1)).to.be.false;
      
      await time.increase(MONTHLY_INTERVAL);
      
      expect(await protocol.isPaymentDue(1)).to.be.true;
    });

    it("should return correct grace period status", async function () {
      await time.increase(MONTHLY_INTERVAL + 1);
      expect(await protocol.isInGracePeriod(1)).to.be.true;

      await time.increase(GRACE_PERIOD);
      expect(await protocol.isInGracePeriod(1)).to.be.false;
    });

    it("should return subscription status", async function () {
      const status = await protocol.getSubscriptionStatus(1);
      expect(status.active).to.be.true;
      expect(status.cancelled).to.be.false;
      expect(status.paymentDue).to.be.false;
      expect(status.amountDue).to.equal(MONTHLY_PRICE);
    });
  });

  describe("Protocol Fees", function () {
    it("should collect fees correctly", async function () {
      await protocol.connect(provider).createPlan(MONTHLY_PRICE, MONTHLY_INTERVAL, GRACE_PERIOD, "Pro", "");
      
      const feeBalanceBefore = await usdc.balanceOf(feeRecipient.address);
      await protocol.connect(subscriber).subscribe(1);
      
      const expectedFee = MONTHLY_PRICE * BigInt(PROTOCOL_FEE_BPS) / BigInt(10000);
      expect(await usdc.balanceOf(feeRecipient.address)).to.equal(feeBalanceBefore + expectedFee);
    });
  });
});
