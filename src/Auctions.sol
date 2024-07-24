// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

//                            _.-^-._    .--.
//                         .-'   _   '-. |__|
//                        /     |_|     \|  |
//                       /               \  |
//                      /|     _____     |\ |
//                       |    |==|==|    |  |
//   |---|---|---|---|---|    |--|--|    |  |
//   |---|---|---|---|---|    |==|==|    |  |
//  ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
//  _______  Harvest.art v3.1 (Auctions) _________

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "solady/src/auth/Ownable.sol";
import "./IBidTicket.sol";

enum Status {
    Active,
    Claimed,
    Refunded,
    Abandoned,
    Withdrawn
}

struct Auction {
    uint8 auctionType;
    address tokenAddress;
    uint64 endTime;
    uint8 tokenCount;
    Status status;
    address highestBidder;
    uint256 highestBid;
    uint256 bidDelta;
    address[] bidders;
    mapping(uint256 => uint256) tokenIds;
    mapping(uint256 => uint256) amounts;
    mapping(address => uint256) rewards;
}

contract Auctions is Ownable {
    uint8 private constant AUCTION_TYPE_ERC721 = 0;
    uint8 private constant AUCTION_TYPE_ERC1155 = 1;

    IBidTicket public bidTicket;

    address public theBarn;
    uint256 public bidTicketTokenId = 1;
    uint256 public bidTicketCostStart = 1;
    uint256 public bidTicketCostBid = 1;
    uint256 public maxTokens = 10;
    uint256 public nextAuctionId = 1;
    uint256 public minStartingBid = 0.05 ether;
    uint256 public minBidIncrement = 0.01 ether;
    uint256 public auctionDuration = 7 days;
    uint256 public settlementDuration = 7 days;
    uint256 public antiSnipeDuration = 1 hours;
    uint256 public abandonmentFeePercent = 20;
    uint256 public outbidRewardPercent = 10;

    mapping(address => uint256) public balances;
    mapping(uint256 => Auction) public auctions;
    mapping(address => mapping(uint256 => bool)) public auctionTokensERC721;
    mapping(address => mapping(uint256 => uint256)) public auctionTokensERC1155;
    
    error AuctionAbandoned();
    error AuctionActive();
    error AuctionClaimed();
    error AuctionEnded();
    error AuctionIsApproved();
    error AuctionNotClaimed();
    error AuctionNotEnded();
    error AuctionRefunded();
    error AuctionWithdrawn();
    error BidTooLow();
    error InvalidFeePercentage();
    error InvalidLengthOfAmounts();
    error InvalidLengthOfTokenIds();
    error InvalidValue();
    error IsHighestBidder();
    error MaxTokensPerTxReached();
    error NoBalanceToWithdraw();
    error NotEnoughTokensInSupply();
    error NotHighestBidder();
    error SettlementPeriodNotExpired();
    error SettlementPeriodEnded();
    error StartPriceTooLow();
    error TokenAlreadyInAuction();
    error TokenNotOwned();
    error TransferFailed();

    event Abandoned(uint256 indexed auctionId, address indexed bidder, uint256 indexed fee);
    event AuctionStarted(address indexed bidder, address indexed tokenAddress, uint256[] indexed tokenIds);
    event Claimed(uint256 indexed auctionId, address indexed winner);
    event NewBid(uint256 indexed auctionId, address indexed bidder, uint256 indexed value);
    event Refunded(uint256 indexed auctionId, address indexed bidder, uint256 indexed value);
    event Withdraw(uint256 indexed auctionId, address indexed bidder, uint256 indexed value);
    event WithdrawBalance(address indexed user, uint256 indexed value);

    constructor(address theBarn_, address bidTicket_) {
        _initializeOwner(msg.sender);
        theBarn = theBarn_;
        bidTicket = IBidTicket(bidTicket_);
    }

    /**
     *
     * startAuction - Starts an auction for a given token
     *
     * @param tokenAddress - The address of the token contract
     * @param tokenIds - The token ids to auction
     *
     */

    function startAuctionERC721(
        uint256 startingBid,
        address tokenAddress,
        uint256[] calldata tokenIds
    ) external payable {
        if (startingBid < minStartingBid) revert StartPriceTooLow();
        if (tokenIds.length == 0) revert InvalidLengthOfTokenIds();
        if (tokenIds.length > maxTokens) revert MaxTokensPerTxReached();

        _processPayment(startingBid);

        Auction storage auction = auctions[nextAuctionId];

        auction.auctionType = AUCTION_TYPE_ERC721;
        auction.tokenAddress = tokenAddress;
        auction.endTime = uint64(block.timestamp + auctionDuration);
        auction.highestBidder = msg.sender;
        auction.highestBid = startingBid;
        auction.tokenCount = uint8(tokenIds.length);

        mapping(uint256 => uint256) storage tokenMap = auction.tokenIds;

        for (uint256 i; i < tokenIds.length; ++i) {
            tokenMap[i] = tokenIds[i];
        }

        unchecked {
            ++nextAuctionId;
        }

        emit AuctionStarted(msg.sender, tokenAddress, tokenIds);
        
        bidTicket.burn(msg.sender, bidTicketTokenId, bidTicketCostStart);

        _validateAuctionTokensERC721(tokenAddress, tokenIds);
    }

    /**
     *
     * startAuction - Starts an auction for a given token
     *
     * @param tokenAddress - The address of the token contract
     * @param tokenIds - The token ids to auction
     * @param amounts - The amounts of each token to auction
     *
     */

    function startAuctionERC1155(
        uint256 startingBid,
        address tokenAddress,
        uint256[] calldata tokenIds,
        uint256[] calldata amounts
    ) external payable {
        if (startingBid < minStartingBid) revert StartPriceTooLow();
        if (tokenIds.length == 0) revert InvalidLengthOfTokenIds();
        if (tokenIds.length != amounts.length) revert InvalidLengthOfAmounts();

        _processPayment(startingBid);

        Auction storage auction = auctions[nextAuctionId];

        auction.auctionType = AUCTION_TYPE_ERC1155;
        auction.tokenAddress = tokenAddress;
        auction.endTime = uint64(block.timestamp + auctionDuration);
        auction.highestBidder = msg.sender;
        auction.highestBid = startingBid;
        auction.tokenCount = uint8(tokenIds.length);

        mapping(uint256 => uint256) storage tokenMap = auction.tokenIds;
        mapping(uint256 => uint256) storage amountMap = auction.amounts;

        for (uint256 i; i < tokenIds.length; ++i) {
            tokenMap[i] = tokenIds[i];
            amountMap[i] = amounts[i];
        }

        unchecked {
            ++nextAuctionId;
        }

        emit AuctionStarted(msg.sender, tokenAddress, tokenIds);

        bidTicket.burn(msg.sender, bidTicketTokenId, bidTicketCostStart);

        _validateAuctionTokensERC1155(tokenAddress, tokenIds, amounts);
    }

    /**
     * bid - Places a bid on an auction
     *
     * @param auctionId - The id of the auction to bid on
     *
     */

    function bid(uint256 auctionId, uint256 bidAmount) external payable {
        Auction storage auction = auctions[auctionId];

        if (auction.highestBidder == msg.sender) revert IsHighestBidder();
        if (bidAmount < auction.highestBid + minBidIncrement) revert BidTooLow();
        if (block.timestamp > auction.endTime) revert AuctionEnded();

        if (block.timestamp >= auction.endTime - antiSnipeDuration) {
            auction.endTime += uint64(antiSnipeDuration);
        }

        _processPayment(bidAmount);

        address prevHighestBidder = auction.highestBidder;
        uint256 prevHighestBid = auction.highestBid;
        uint256 bidDelta = bidAmount - prevHighestBid;

        if (prevHighestBidder != address(0)) {
            unchecked {
                balances[prevHighestBidder] += prevHighestBid;

                uint256 reward = bidDelta * outbidRewardPercent / 100;
                auction.rewards[prevHighestBidder] += reward;

                if (auction.rewards[prevHighestBidder] == reward) {
                    auction.bidders.push(prevHighestBidder);
                }
            }
        }

        auction.highestBidder = msg.sender;
        auction.highestBid = bidAmount;

        emit NewBid(auctionId, msg.sender, bidAmount);

        bidTicket.burn(msg.sender, bidTicketTokenId, bidTicketCostBid);
    }

    /**
     * claim - Claims the tokens from an auction
     *
     * @param auctionId - The id of the auction to claim
     *
     */

    function claim(uint256 auctionId) external {
        Auction storage auction = auctions[auctionId];

        if (block.timestamp < auction.endTime) revert AuctionNotEnded();
        if (msg.sender != auction.highestBidder) revert NotHighestBidder();

        if (auction.status != Status.Active) {
            if (auction.status == Status.Refunded) revert AuctionRefunded();
            if (auction.status == Status.Claimed) revert AuctionClaimed();
            if (auction.status == Status.Abandoned) revert AuctionAbandoned();
        }

        auction.status = Status.Claimed;
        
        _distributeRewards(auction);

        emit Claimed(auctionId, msg.sender);

        if (auction.auctionType == AUCTION_TYPE_ERC721) {
            _transferERC721s(auction);
        } else {
            _transferERC1155s(auction);
        }
    }

    /**
     * refund - Refunds are available during the settlement period if The Barn has not yet approved the collection
     *
     * @param auctionId - The id of the auction to refund
     *
     */
    function refund(uint256 auctionId) external {
        Auction storage auction = auctions[auctionId];
        uint256 highestBid = auction.highestBid;
        uint256 endTime = auction.endTime;

        if (block.timestamp < endTime) revert AuctionActive();
        if (block.timestamp > endTime + settlementDuration) revert SettlementPeriodEnded();
        if (msg.sender != auction.highestBidder) revert NotHighestBidder();

        if (auction.status != Status.Active) {
            if (auction.status == Status.Refunded) revert AuctionRefunded();
            if (auction.status == Status.Claimed) revert AuctionClaimed();
            if (auction.status == Status.Withdrawn) revert AuctionWithdrawn();
        }

        auction.status = Status.Refunded;

        emit Refunded(auctionId, msg.sender, highestBid);

        if (auction.auctionType == AUCTION_TYPE_ERC721) {
            _checkAndResetERC721s(auction);
        } else {
            _checkAndResetERC1155s(auction);
        }

        (bool success,) = payable(msg.sender).call{value: highestBid}("");
        if (!success) revert TransferFailed();
    }

    /**
     *
     * abandon - Mark unclaimed auctions as abandoned after the settlement period
     *
     * @param auctionId - The id of the auction to abandon
     *
     */
    function abandon(uint256 auctionId) external onlyOwner {
        Auction storage auction = auctions[auctionId];
        address highestBidder = auction.highestBidder;
        uint256 highestBid = auction.highestBid;

        if (block.timestamp < auction.endTime + settlementDuration) revert SettlementPeriodNotExpired();

        if (auction.status != Status.Active) {
            if (auction.status == Status.Abandoned) revert AuctionAbandoned();
            if (auction.status == Status.Refunded) revert AuctionRefunded();
            if (auction.status == Status.Claimed) revert AuctionClaimed();
        }

        auction.status = Status.Abandoned;

        if (auction.auctionType == AUCTION_TYPE_ERC721) {
            _resetERC721s(auction);
        } else {
            _resetERC1155s(auction);
        }

        uint256 fee = highestBid * abandonmentFeePercent / 100;

        balances[highestBidder] += highestBid - fee;

        emit Abandoned(auctionId, highestBidder, fee);

        (bool success,) = payable(msg.sender).call{value: fee}("");
        if (!success) revert TransferFailed();
    }

    /**
     * withdraw - Withdraws the highest bid from claimed auctions
     *
     * @param auctionIds - The ids of the auctions to withdraw from
     *
     * @notice - Auctions can only be withdrawn after the settlement period has ended.
     *
     */

    function withdraw(uint256[] calldata auctionIds) external onlyOwner {
        uint256 totalAmount;

        for (uint256 i; i < auctionIds.length;) {
            Auction storage auction = auctions[auctionIds[i]];

            if (auction.status != Status.Claimed) revert AuctionNotClaimed();

            totalAmount += auction.highestBid;
            auction.status = Status.Withdrawn;

            unchecked {
                ++i;
            }
        }

        (bool success,) = payable(msg.sender).call{value: totalAmount}("");
        if (!success) revert TransferFailed();
    }

    /**
     * withdrawBalance - Withdraws the balance of the user.
     *
     * @notice - We keep track of the balance instead of sending it directly
     *           back to the user when outbid to avoid re-entrancy attacks.
     *
     */
    function withdrawBalance() external {
        uint256 balance = balances[msg.sender];
        if (balance == 0) revert NoBalanceToWithdraw();

        balances[msg.sender] = 0;

        emit WithdrawBalance(msg.sender, balance);

        (bool success,) = payable(msg.sender).call{value: balance}("");
        if (!success) revert TransferFailed();
    }

    /**
     *
     * Getters & Setters
     *
     */

    function getAuctionTokens(uint256 auctionId) external view returns (uint256[] memory, uint256[] memory) {
        Auction storage auction = auctions[auctionId];

        uint256[] memory tokenIds = new uint256[](auction.tokenCount);
        uint256[] memory amounts = new uint256[](auction.tokenCount);

        uint256 tokenCount = auction.tokenCount;

        for (uint256 i; i < tokenCount;) {
            tokenIds[i] = auction.tokenIds[i];
            if (auction.auctionType == AUCTION_TYPE_ERC721) {
                amounts[i] = 1;
            } else {
                amounts[i] = auction.amounts[i];
            }

            unchecked {
                ++i;
            }
        }

        return (tokenIds, amounts);
    }

    function getRewards(address bidder, uint256[] calldata auctionIds) external view returns (uint256) {
        uint256 totalRewards;

        for (uint256 i; i < auctionIds.length; ++i) {
            if (auctions[auctionIds[i]].status == Status.Claimed) {
                totalRewards += auctions[auctionIds[i]].rewards[bidder];
            }
        }

        return totalRewards;
    }

    function setBarnAddress(address theBarn_) external onlyOwner {
        theBarn = theBarn_;
    }

    function setBidTicketAddress(address bidTicket_) external onlyOwner {
        bidTicket = IBidTicket(bidTicket_);
    }

    function setBidTicketTokenId(uint256 bidTicketTokenId_) external onlyOwner {
        bidTicketTokenId = bidTicketTokenId_;
    }

    function setBidTicketCostStart(uint256 bidTicketCostStart_) external onlyOwner {
        bidTicketCostStart = bidTicketCostStart_;
    }

    function setBidTicketCostBid(uint256 bidTicketCostBid_) external onlyOwner {
        bidTicketCostBid = bidTicketCostBid_;
    }

    function setMaxTokens(uint256 maxTokens_) external onlyOwner {
        maxTokens = maxTokens_;
    }

    function setMinStartingBid(uint256 minStartingBid_) external onlyOwner {
        minStartingBid = minStartingBid_;
    }

    function setMinBidIncrement(uint256 minBidIncrement_) external onlyOwner {
        minBidIncrement = minBidIncrement_;
    }

    function setAuctionDuration(uint256 auctionDuration_) external onlyOwner {
        auctionDuration = auctionDuration_;
    }

    function setSettlementDuration(uint256 settlementDuration_) external onlyOwner {
        settlementDuration = settlementDuration_;
    }

    function setAntiSnipeDuration(uint256 antiSnipeDuration_) external onlyOwner {
        antiSnipeDuration = antiSnipeDuration_;
    }

    function setAbandonmentFeePercent(uint256 newFeePercent) external onlyOwner {
        if (newFeePercent > 100) revert InvalidFeePercentage();
        abandonmentFeePercent = newFeePercent;
    }

    function setOutbidRewardPercent(uint256 newPercent) external onlyOwner {
        if (newPercent > 100) revert InvalidFeePercentage();
        outbidRewardPercent = newPercent;
    }

    /**
     *
     * Internal Functions
     *
     */

    function _processPayment(uint256 payment) internal {
        uint256 balance = balances[msg.sender];
        uint256 paymentFromBalance;
        uint256 paymentFromMsgValue;

        if (balance >= payment) {
            paymentFromBalance = payment;
            paymentFromMsgValue = 0;
        } else {
            paymentFromBalance = balance;
            paymentFromMsgValue = payment - balance;
        }

        if (msg.value != paymentFromMsgValue) {
            revert InvalidValue();
        }

        if (paymentFromBalance > 0) {
            balances[msg.sender] -= paymentFromBalance;
        }
    }

    function _validateAuctionTokensERC721(address tokenAddress, uint256[] calldata tokenIds) internal {
        IERC721 erc721Contract = IERC721(tokenAddress);

        mapping(uint256 => bool) storage auctionTokens = auctionTokensERC721[tokenAddress];

        for (uint256 i; i < tokenIds.length;) {
            uint256 tokenId = tokenIds[i];

            if (auctionTokens[tokenId]) revert TokenAlreadyInAuction();

            auctionTokens[tokenId] = true;

            if (erc721Contract.ownerOf(tokenId) != theBarn) revert TokenNotOwned();

            unchecked {
                ++i;
            }
        }
    }

    function _validateAuctionTokensERC1155(
        address tokenAddress,
        uint256[] calldata tokenIds,
        uint256[] calldata amounts
    ) internal {
        IERC1155 erc1155Contract = IERC1155(tokenAddress);
        uint256 totalTokens;
        uint256 totalNeeded;
        uint256 balance;
        uint256 tokenId;
        uint256 amount;

        mapping(uint256 => uint256) storage auctionTokens = auctionTokensERC1155[tokenAddress];

        for (uint256 i; i < tokenIds.length;) {
            tokenId = tokenIds[i];
            amount = amounts[i];

            totalTokens += amount;
            totalNeeded = auctionTokens[tokenId] + amount;
            balance = erc1155Contract.balanceOf(theBarn, tokenId);

            if (totalNeeded > balance) revert NotEnoughTokensInSupply();

            unchecked {
                auctionTokens[tokenId] += amount;
                ++i;
            }
        }

        if (totalTokens > maxTokens) revert MaxTokensPerTxReached();
    }

    function _transferERC721s(Auction storage auction) internal {
        address tokenAddress = auction.tokenAddress;
        uint256 tokenCount = auction.tokenCount;
        address highestBidder = auction.highestBidder;
        IERC721 erc721Contract = IERC721(tokenAddress);

        mapping(uint256 => uint256) storage tokenMap = auction.tokenIds;
        mapping(uint256 => bool) storage auctionTokens = auctionTokensERC721[tokenAddress];

        for (uint256 i; i < tokenCount;) {
            uint256 tokenId = tokenMap[i];
            auctionTokens[tokenId] = false;
            erc721Contract.transferFrom(theBarn, highestBidder, tokenId);

            unchecked {
                ++i;
            }
        }
    }

    function _transferERC1155s(Auction storage auction) internal {
        address tokenAddress = auction.tokenAddress;
        IERC1155 erc1155Contract = IERC1155(tokenAddress);
        uint256 tokenCount = auction.tokenCount;
        uint256[] memory tokenIds = new uint256[](tokenCount);
        uint256[] memory amounts = new uint256[](tokenCount);

        mapping(uint256 => uint256) storage tokenMap = auction.tokenIds;
        mapping(uint256 => uint256) storage amountMap = auction.amounts;
        mapping(uint256 => uint256) storage auctionTokens = auctionTokensERC1155[tokenAddress];

        for (uint256 i; i < tokenCount;) {
            uint256 tokenId = tokenMap[i];
            uint256 amount = amountMap[i];

            tokenIds[i] = tokenId;
            amounts[i] = amount;
            auctionTokens[tokenId] -= amount;

            unchecked {
                ++i;
            }
        }

        erc1155Contract.safeBatchTransferFrom(theBarn, auction.highestBidder, tokenIds, amounts, "");
    }

    function _resetERC721s(Auction storage auction) internal {
        address tokenAddress = auction.tokenAddress;
        uint256 tokenCount = auction.tokenCount;

        mapping(uint256 => uint256) storage tokenMap = auction.tokenIds;
        mapping(uint256 => bool) storage auctionTokens = auctionTokensERC721[tokenAddress];

        for (uint256 i; i < tokenCount;) {
            uint256 tokenId = tokenMap[i];
            auctionTokens[tokenId] = false;

            unchecked {
                ++i;
            }
        }
    }

    function _resetERC1155s(Auction storage auction) internal {
        address tokenAddress = auction.tokenAddress;
        uint256 tokenCount = auction.tokenCount;
        uint256[] memory tokenIds = new uint256[](tokenCount);
        uint256[] memory amounts = new uint256[](tokenCount);

        mapping(uint256 => uint256) storage tokenMap = auction.tokenIds;
        mapping(uint256 => uint256) storage amountMap = auction.amounts;
        mapping(uint256 => uint256) storage auctionTokens = auctionTokensERC1155[tokenAddress];

        for (uint256 i; i < tokenCount;) {
            uint256 tokenId = tokenMap[i];
            uint256 amount = amountMap[i];

            tokenIds[i] = tokenId;
            amounts[i] = amount;
            auctionTokens[tokenId] -= amount;

            unchecked {
                ++i;
            }
        }
    }

    function _checkAndResetERC721s(Auction storage auction) internal {
        address tokenAddress = auction.tokenAddress;
        uint256 tokenCount = auction.tokenCount;

        mapping(uint256 => uint256) storage tokenMap = auction.tokenIds;
        mapping(uint256 => bool) storage auctionTokens = auctionTokensERC721[tokenAddress];

        bool notRefundable = IERC721(tokenAddress).isApprovedForAll(theBarn, address(this));

        for (uint256 i; i < tokenCount;) {
            uint256 tokenId = tokenMap[i];
            auctionTokens[tokenId] = false;

            notRefundable = notRefundable && (IERC721(tokenAddress).ownerOf(tokenId) == theBarn);

            unchecked {
                ++i;
            }
        }

        if (notRefundable) revert AuctionIsApproved();
    }

    function _checkAndResetERC1155s(Auction storage auction) internal {
        address tokenAddress = auction.tokenAddress;
        uint256 tokenCount = auction.tokenCount;
        uint256[] memory tokenIds = new uint256[](tokenCount);
        uint256[] memory amounts = new uint256[](tokenCount);

        mapping(uint256 => uint256) storage tokenMap = auction.tokenIds;
        mapping(uint256 => uint256) storage amountMap = auction.amounts;
        mapping(uint256 => uint256) storage auctionTokens = auctionTokensERC1155[tokenAddress];

        bool notRefundable = IERC1155(tokenAddress).isApprovedForAll(theBarn, address(this));

        for (uint256 i; i < tokenCount;) {
            uint256 tokenId = tokenMap[i];
            uint256 amount = amountMap[i];

            tokenIds[i] = tokenId;
            amounts[i] = amount;
            auctionTokens[tokenId] -= amount;

            notRefundable = notRefundable && (IERC1155(tokenAddress).balanceOf(theBarn, tokenId) >= amount);

            unchecked {
                ++i;
            }
        }

        if (notRefundable) revert AuctionIsApproved();
    }

    function _distributeRewards(Auction storage auction) internal {
        for (uint256 i; i < auction.bidders.length; ++i) {
            address bidder = auction.bidders[i];
            uint256 reward = auction.rewards[bidder];

            if (reward > 0) {
                unchecked {
                    balances[bidder] += reward;
                }
            }
        }
    }
}

