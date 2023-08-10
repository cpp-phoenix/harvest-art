// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/HarvestMarket.sol";

contract HarvestMarketTest is Test {
    HarvestMarket market;
    address public tokenAddress1;
    address public user1;
    address public user2;
    uint256[] tokenIds = [1, 2, 3];

    receive() external payable {}
    fallback() external payable {}

    function setUp() public {
        market = new HarvestMarket();
        market.setBarnAddress(payable(address(this)));
        user1 = vm.addr(1);
        user2 = vm.addr(2);
        vm.deal(user1, 1 ether);
        vm.deal(user2, 1 ether);
        vm.startPrank(user1);
    }

    function testStartAuction() public {
        uint256 startBalance = user1.balance;

        market.startAuction{value: 0.05 ether}(tokenAddress1, tokenIds);
        assertEq(user1.balance, startBalance - 0.05 ether, "Balance should decrease by 0.05 ether");
        assertEq(market.nextAuctionId(), 2, "nextAuctionId should be incremented");

        (address tokenAddress, address highestBidder,,, uint256 highestBid,,) = market.auctions(1);

        assertEq(tokenAddress, tokenAddress1);
        assertEq(highestBidder, user1);
        assertEq(highestBid, 0.05 ether);
    }

    function testBid() public {
        market.startAuction{value: 0.05 ether}(tokenAddress1, tokenIds);
        market.bid{value: 0.06 ether}(1);

        (, address highestBidder,,, uint256 highestBid,,) = market.auctions(1);

        assertEq(highestBidder, user1, "Highest bidder should be this contract");
        assertEq(highestBid, 0.06 ether, "Highest bid should be 0.06 ether");
    }

    function testBidBelowMinimumIncrement() public {
        market.startAuction{value: 0.05 ether}(tokenAddress1, tokenIds);
        try market.bid{value: 0.055 ether}(1) {
            fail("Should not allow bids below the minimum increment");
        } catch {}

        (,,,, uint256 highestBid,,) = market.auctions(1);
        assertEq(highestBid, 0.05 ether, "Highest bid should remain 0.05 ether");
    }

    function testRevertOnEqualBid() public {
        market.startAuction{value: 0.05 ether}(tokenAddress1, tokenIds);
        uint256 auctionId = market.nextAuctionId() - 1;

        market.bid{value: 0.06 ether}(auctionId);

        try market.bid{value: 0.06 ether}(auctionId) {
            fail("Should have reverted on equal bid");
        } catch {}
    }

    function testBidAfterAuctionEnded() public {
        market.startAuction{value: 0.05 ether}(tokenAddress1, tokenIds);

        skip(60 * 60 * 24 * 7 + 1);

        try market.bid{value: 0.06 ether}(1) {
            fail("Should not allow bids after the auction has ended");
        } catch {}

        (,,,, uint256 highestBid,,) = market.auctions(1);
        assertEq(highestBid, 0.05 ether, "Highest bid should remain 0.05 ether");
    }

    function testClaim() public {
        market.startAuction{value: 0.05 ether}(tokenAddress1, tokenIds);
        market.bid{value: 0.06 ether}(1);

        (, address highestBidder,,, uint256 highestBid,,) = market.auctions(1);

        assertEq(highestBidder, user1, "Highest bidder should be this contract");
        assertEq(highestBid, 0.06 ether, "Highest bid should be 0.06 ether");
    }

    function testClaimBeforeAuctionEnded() public {
        market.startAuction{value: 0.05 ether}(tokenAddress1, tokenIds);
        try market.claim(1) {
            fail("Should not allow claiming before the auction has ended");
        } catch {}

        (, address highestBidder,,,,,) = market.auctions(1);
        assertEq(highestBidder, user1, "Highest bidder should remain unchanged");
    }

    function testClaimByNonHighestBidder() public {
        market.startAuction{value: 0.05 ether}(tokenAddress1, tokenIds);

        skip(60 * 60 * 24 * 7 + 1);

        vm.startPrank(user2);
        try market.claim(1) {
            fail("Should not allow non-highest bidders to claim");
        } catch {}
        vm.stopPrank();

        (, address highestBidder,,,,,) = market.auctions(1);
        assertEq(highestBidder, user1, "Highest bidder should remain unchanged");
    }

    function testStartAuctionWithTooManyTokens() public {
        uint256[] memory manyTokenIds = new uint256[](1001);

        try market.startAuction{value: 0.05 ether}(tokenAddress1, manyTokenIds) {
            fail("Should not allow creating an auction with too many tokens");
        } catch {}

        uint256 nextAuctionId = market.nextAuctionId();
        assertEq(nextAuctionId, 1, "nextAuctionId should remain unchanged");
    }

    function testStartAuctionWithLowStartPrice() public {
        try market.startAuction{value: 0.04 ether}(tokenAddress1, tokenIds) {
            fail("Should not allow creating an auction with a start price below the minimum");
        } catch {}

        uint256 nextAuctionId = market.nextAuctionId();
        assertEq(nextAuctionId, 1, "nextAuctionId should remain unchanged");
    }

    function testSuccessfulWithdrawal() public {
        market.startAuction{value: 0.05 ether}(tokenAddress1, tokenIds);

        uint256 auctionId = market.nextAuctionId() - 1;
        uint256[] memory auctionIds = new uint256[](1);
        auctionIds[0] = auctionId;

        skip(60 * 60 * 24 * 7 + 1);

        vm.startPrank(address(this));
        market.withdraw(auctionIds);

        (,,,,,, bool withdrawn) = market.auctions(auctionId);
        assertTrue(withdrawn, "Auction should be marked as withdrawn");
    }

    function testRevertOnActiveAuctionWithdrawal() public {
        market.startAuction{value: 0.05 ether}(tokenAddress1, tokenIds);

        uint256 auctionId = market.nextAuctionId() - 1;
        uint256[] memory auctionIds = new uint256[](1);
        auctionIds[0] = auctionId;

        skip(60 * 60 * 24 * 7 + 1);

        vm.startPrank(address(this));
        market.withdraw(auctionIds);

        try market.withdraw(auctionIds) {
            fail("Should have reverted on active auction withdrawal");
        } catch {}
    }

    function testRevertOnAlreadyWithdrawnAuction() public {
        market.startAuction{value: 0.05 ether}(tokenAddress1, tokenIds);

        uint256 auctionId = market.nextAuctionId() - 1;
        uint256[] memory auctionIds = new uint256[](1);
        auctionIds[0] = auctionId;

        skip(60 * 60 * 24 * 7 + 1);

        vm.startPrank(address(this));
        market.withdraw(auctionIds);

        try market.withdraw(auctionIds) {
            fail("Should have reverted on already withdrawn auction");
        } catch {}
    }

    function testSetMinStartPrice() public {
        vm.stopPrank();

        vm.startPrank(address(this));
        market.setMinStartPrice(0.01 ether);
        vm.stopPrank();

        vm.startPrank(user1);
        market.startAuction{value: 0.01 ether}(tokenAddress1, tokenIds);
    }

    function testSetMinBidIncrement() public {
        vm.stopPrank();

        vm.startPrank(address(this));
        market.setMinBidIncrement(0.02 ether);
        vm.stopPrank();

        vm.startPrank(user1);
        market.startAuction{value: 0.05 ether}(tokenAddress1, tokenIds);

        market.bid{value: 0.07 ether}(1);

        try market.bid{value: 0.08 ether}(1) {
            fail("Should not allow bids below the minimum increment");
        } catch {}
    }
}
