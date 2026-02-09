const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("BATHRON_HTLC", function () {
  let htlc;
  let mockToken;
  let lp, taker, other;

  // Test secret and hashlock
  const secret = ethers.encodeBytes32String("test_secret_12345678901234");
  let hashlock;

  // Compute SHA256 hashlock (same as BATHRON)
  function computeHashlock(preimage) {
    // SHA256 (not keccak256!)
    return ethers.sha256(ethers.solidityPacked(["bytes32"], [preimage]));
  }

  beforeEach(async function () {
    [lp, taker, other] = await ethers.getSigners();

    // Deploy HTLC
    const BATHRON_HTLC = await ethers.getContractFactory("BATHRON_HTLC");
    htlc = await BATHRON_HTLC.deploy();

    // Deploy mock ERC20 token
    const MockToken = await ethers.getContractFactory("MockERC20");
    mockToken = await MockToken.deploy("Mock USDC", "USDC", 6);

    // Mint tokens to taker
    await mockToken.mint(taker.address, ethers.parseUnits("1000", 6));

    // Compute hashlock
    hashlock = computeHashlock(secret);
  });

  describe("Deployment", function () {
    it("Should deploy successfully", async function () {
      expect(await htlc.getAddress()).to.be.properAddress;
    });

    it("Should have correct constants", async function () {
      expect(await htlc.MIN_TIMELOCK()).to.equal(3600); // 1 hour
      expect(await htlc.MAX_TIMELOCK()).to.equal(30 * 24 * 3600); // 30 days
    });
  });

  describe("Lock ERC20", function () {
    it("Should lock tokens successfully", async function () {
      const amount = ethers.parseUnits("100", 6);
      const timelock = (await time.latest()) + 86400; // +1 day
      const swapId = ethers.keccak256(ethers.toUtf8Bytes("swap1"));

      // Approve
      await mockToken.connect(taker).approve(await htlc.getAddress(), amount);

      // Lock
      await expect(
        htlc.connect(taker).lock(swapId, lp.address, await mockToken.getAddress(), amount, hashlock, timelock)
      )
        .to.emit(htlc, "Locked")
        .withArgs(swapId, lp.address, taker.address, await mockToken.getAddress(), amount, hashlock, timelock);

      // Verify swap
      const swap = await htlc.getSwap(swapId);
      expect(swap.lp).to.equal(lp.address);
      expect(swap.taker).to.equal(taker.address);
      expect(swap.amount).to.equal(amount);
      expect(swap.hashlock).to.equal(hashlock);
      expect(swap.claimed).to.be.false;
      expect(swap.refunded).to.be.false;
    });

    it("Should reject duplicate swapId", async function () {
      const amount = ethers.parseUnits("100", 6);
      const timelock = (await time.latest()) + 86400;
      const swapId = ethers.keccak256(ethers.toUtf8Bytes("swap1"));

      await mockToken.connect(taker).approve(await htlc.getAddress(), amount * 2n);
      await htlc.connect(taker).lock(swapId, lp.address, await mockToken.getAddress(), amount, hashlock, timelock);

      await expect(
        htlc.connect(taker).lock(swapId, lp.address, await mockToken.getAddress(), amount, hashlock, timelock)
      ).to.be.revertedWithCustomError(htlc, "SwapExists");
    });

    it("Should reject invalid timelock (too soon)", async function () {
      const amount = ethers.parseUnits("100", 6);
      const timelock = (await time.latest()) + 1800; // +30 min (< MIN_TIMELOCK)
      const swapId = ethers.keccak256(ethers.toUtf8Bytes("swap1"));

      await mockToken.connect(taker).approve(await htlc.getAddress(), amount);

      await expect(
        htlc.connect(taker).lock(swapId, lp.address, await mockToken.getAddress(), amount, hashlock, timelock)
      ).to.be.revertedWithCustomError(htlc, "InvalidTimelock");
    });
  });

  describe("Lock ETH", function () {
    it("Should lock ETH successfully", async function () {
      const amount = ethers.parseEther("1");
      const timelock = (await time.latest()) + 86400;
      const swapId = ethers.keccak256(ethers.toUtf8Bytes("ethswap1"));

      await expect(
        htlc.connect(taker).lockETH(swapId, lp.address, hashlock, timelock, { value: amount })
      )
        .to.emit(htlc, "Locked")
        .withArgs(swapId, lp.address, taker.address, ethers.ZeroAddress, amount, hashlock, timelock);

      // Verify contract balance
      expect(await ethers.provider.getBalance(await htlc.getAddress())).to.equal(amount);
    });
  });

  describe("Claim", function () {
    let swapId;
    const amount = ethers.parseUnits("100", 6);

    beforeEach(async function () {
      swapId = ethers.keccak256(ethers.toUtf8Bytes("claimtest"));
      const timelock = (await time.latest()) + 86400;

      await mockToken.connect(taker).approve(await htlc.getAddress(), amount);
      await htlc.connect(taker).lock(swapId, lp.address, await mockToken.getAddress(), amount, hashlock, timelock);
    });

    it("Should claim with correct preimage", async function () {
      const lpBalanceBefore = await mockToken.balanceOf(lp.address);

      await expect(htlc.connect(lp).claim(swapId, secret))
        .to.emit(htlc, "Claimed")
        .withArgs(swapId, secret);

      const lpBalanceAfter = await mockToken.balanceOf(lp.address);
      expect(lpBalanceAfter - lpBalanceBefore).to.equal(amount);

      // Verify swap is completed
      const swap = await htlc.getSwap(swapId);
      expect(swap.claimed).to.be.true;
    });

    it("Should allow anyone to call claim (tokens go to LP)", async function () {
      // Other person calls claim, but LP gets tokens
      await htlc.connect(other).claim(swapId, secret);

      expect(await mockToken.balanceOf(lp.address)).to.equal(amount);
      expect(await mockToken.balanceOf(other.address)).to.equal(0);
    });

    it("Should reject wrong preimage", async function () {
      const wrongSecret = ethers.encodeBytes32String("wrong_secret_xxxxxxx");

      await expect(htlc.connect(lp).claim(swapId, wrongSecret)).to.be.revertedWithCustomError(htlc, "InvalidPreimage");
    });

    it("Should reject claim after timelock", async function () {
      await time.increase(86401); // +1 day + 1 second

      await expect(htlc.connect(lp).claim(swapId, secret)).to.be.revertedWithCustomError(htlc, "TimelockExpired");
    });

    it("Should reject double claim", async function () {
      await htlc.connect(lp).claim(swapId, secret);

      await expect(htlc.connect(lp).claim(swapId, secret)).to.be.revertedWithCustomError(htlc, "SwapCompleted");
    });
  });

  describe("Refund", function () {
    let swapId;
    const amount = ethers.parseUnits("100", 6);

    beforeEach(async function () {
      swapId = ethers.keccak256(ethers.toUtf8Bytes("refundtest"));
      const timelock = (await time.latest()) + 86400;

      await mockToken.connect(taker).approve(await htlc.getAddress(), amount);
      await htlc.connect(taker).lock(swapId, lp.address, await mockToken.getAddress(), amount, hashlock, timelock);
    });

    it("Should refund after timelock expires", async function () {
      const takerBalanceBefore = await mockToken.balanceOf(taker.address);

      await time.increase(86401); // +1 day + 1 second

      await expect(htlc.connect(taker).refund(swapId)).to.emit(htlc, "Refunded").withArgs(swapId);

      const takerBalanceAfter = await mockToken.balanceOf(taker.address);
      expect(takerBalanceAfter - takerBalanceBefore).to.equal(amount);

      // Verify swap is completed
      const swap = await htlc.getSwap(swapId);
      expect(swap.refunded).to.be.true;
    });

    it("Should allow anyone to call refund (tokens go to Taker)", async function () {
      await time.increase(86401);

      // Other person calls refund, but Taker gets tokens
      const takerBalanceBefore = await mockToken.balanceOf(taker.address);
      await htlc.connect(other).refund(swapId);
      const takerBalanceAfter = await mockToken.balanceOf(taker.address);

      expect(takerBalanceAfter - takerBalanceBefore).to.equal(amount);
    });

    it("Should reject refund before timelock", async function () {
      await expect(htlc.connect(taker).refund(swapId)).to.be.revertedWithCustomError(htlc, "TimelockNotExpired");
    });

    it("Should reject refund if already claimed", async function () {
      await htlc.connect(lp).claim(swapId, secret);

      await time.increase(86401);

      await expect(htlc.connect(taker).refund(swapId)).to.be.revertedWithCustomError(htlc, "SwapCompleted");
    });
  });

  describe("View Functions", function () {
    let swapId;
    const amount = ethers.parseUnits("100", 6);

    beforeEach(async function () {
      swapId = ethers.keccak256(ethers.toUtf8Bytes("viewtest"));
      const timelock = (await time.latest()) + 86400;

      await mockToken.connect(taker).approve(await htlc.getAddress(), amount);
      await htlc.connect(taker).lock(swapId, lp.address, await mockToken.getAddress(), amount, hashlock, timelock);
    });

    it("Should return correct isActive", async function () {
      expect(await htlc.isActive(swapId)).to.be.true;

      await htlc.connect(lp).claim(swapId, secret);

      expect(await htlc.isActive(swapId)).to.be.false;
    });

    it("Should verify preimage correctly", async function () {
      expect(await htlc.verifyPreimage(swapId, secret)).to.be.true;

      const wrongSecret = ethers.encodeBytes32String("wrong_secret_xxxxxxx");
      expect(await htlc.verifyPreimage(swapId, wrongSecret)).to.be.false;
    });

    it("Should compute swapId deterministically", async function () {
      const nonce = 12345;
      const computed = await htlc.computeSwapId(lp.address, taker.address, hashlock, nonce);

      const expected = ethers.keccak256(
        ethers.solidityPacked(["address", "address", "bytes32", "uint256"], [lp.address, taker.address, hashlock, nonce])
      );

      expect(computed).to.equal(expected);
    });
  });

  describe("Full Atomic Swap Flow", function () {
    it("Should complete full swap: lock -> claim -> secret revealed", async function () {
      // 1. Taker generates secret
      const takerSecret = ethers.encodeBytes32String("atomic_swap_secret_123");
      const takerHashlock = computeHashlock(takerSecret);

      // 2. Setup swap
      const swapId = ethers.keccak256(ethers.toUtf8Bytes("fullswap"));
      const amount = ethers.parseUnits("100", 6);
      const timelock = (await time.latest()) + 86400;

      // 3. Taker locks tokens (simulates locking on EVM after LP created LOT on BATHRON)
      await mockToken.connect(taker).approve(await htlc.getAddress(), amount);
      await htlc.connect(taker).lock(swapId, lp.address, await mockToken.getAddress(), amount, takerHashlock, timelock);

      // 4. At this point:
      //    - BATHRON: LOT exists with takerHashlock
      //    - EVM: HTLC exists with takerHashlock
      //    - Secret is only known to Taker

      // 5. Taker reveals secret on BATHRON (claim M1)
      //    This makes takerSecret PUBLIC in BATHRON transaction

      // 6. LP (or bot) sees takerSecret in BATHRON tx, uses it here
      const tx = await htlc.connect(lp).claim(swapId, takerSecret);
      const receipt = await tx.wait();

      // 7. Verify secret is in the event (PUBLIC)
      const claimedEvent = receipt.logs.find((log) => {
        try {
          const parsed = htlc.interface.parseLog(log);
          return parsed.name === "Claimed";
        } catch {
          return false;
        }
      });

      const parsedEvent = htlc.interface.parseLog(claimedEvent);
      expect(parsedEvent.args.preimage).to.equal(takerSecret);

      // 8. Swap complete - LP has USDC, Taker has M1 (on BATHRON)
      expect(await mockToken.balanceOf(lp.address)).to.equal(amount);
    });
  });
});

// Mock ERC20 for testing
const MockERC20 = `
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    uint8 private _decimals;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
`;
