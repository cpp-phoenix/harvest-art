// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

//                            _.-^-._    .--.
//                         .-'   _   '-. |__|
//                        /     |_|     \|  |
//                       /               \  |
//                      /|     _____     |\ |
//                       |    |==|==|    |  |
//   |---|---|---|---|---|    |--|--|    |  |
//   |---|---|---|---|---|    |==|==|    |  |
//  ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
//  ____________  Harvest.art v3 _____________

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "solady/src/auth/Ownable.sol";
import "../src/IERCBase.sol";

bytes4 constant ERC721_INTERFACE = 0x80ac58cd;
bytes4 constant ERC1155_INTERFACE = 0xd9b67a26;

contract HarvestArt is Ownable {
    address public theBarn = address(0);
    uint256 public defaultPrice = 1 gwei;
    uint256 public maxTokensPerTx = 100;

    mapping(address => uint256) private _contractPrices;

    error BarnNotSet();
    error InvalidTokenContractLength();
    error InvalidParamsLength();
    error InvalidTokenCount();
    error MaxTokensPerTxReached();
    error TokenNotYetApproved();
    error TransferFailed();

    constructor() {
        _initializeOwner(msg.sender);
    }

    function batchTransfer(address[] calldata tokenContracts, uint256[] calldata tokenIds, uint256[] calldata counts)
        external
    {
        if (theBarn == address(0)) {
            revert BarnNotSet();
        }

        if (tokenContracts.length == 0) {
            revert InvalidTokenContractLength();
        }

        if (tokenContracts.length != tokenIds.length || tokenIds.length != counts.length) {
            revert InvalidParamsLength();
        }

        IERCBase tokenContract;
        uint256 totalTokens = 0;
        uint256 totalPrice = 0;

        for (uint256 i = 0; i < tokenContracts.length;) {
            if (counts[i] == 0) revert InvalidTokenCount();

            tokenContract = IERCBase(tokenContracts[i]);

            if (tokenContract.supportsInterface(ERC721_INTERFACE)) {
                totalTokens += 1;
                totalPrice += _getPrice(tokenContracts[i]);
            } else if (tokenContract.supportsInterface(ERC1155_INTERFACE)) {
                totalTokens += counts[i];
                totalPrice += _getPrice(tokenContracts[i]) * counts[i];
            } else {
                continue;
            }

            if (totalTokens > maxTokensPerTx) {
                revert MaxTokensPerTxReached();
            }

            if (!tokenContract.isApprovedForAll(msg.sender, address(this))) {
                revert TokenNotYetApproved();
            }

            if (tokenContract.supportsInterface(ERC721_INTERFACE)) {
                IERC721(tokenContracts[i]).transferFrom(msg.sender, theBarn, tokenIds[i]);
            } else {
                IERC1155(tokenContracts[i]).safeTransferFrom(msg.sender, theBarn, tokenIds[i], counts[i], "");
            }

            unchecked {
                i++;
            }
        }

        (bool sent,) = payable(msg.sender).call{value: totalPrice}("");
        if (!sent) revert TransferFailed();
    }

    function _getPrice(address contractAddress) internal view returns (uint256) {
        if (_contractPrices[contractAddress] > 0) {
            return _contractPrices[contractAddress];
        } else {
            return defaultPrice;
        }
    }

    function setBarn(address _theBarn) public onlyOwner {
        theBarn = _theBarn;
    }

    function setDefaultPrice(uint256 _defaultPrice) public onlyOwner {
        defaultPrice = _defaultPrice;
    }

    function setMaxTokensPerTx(uint256 _maxTokensPerTx) public onlyOwner {
        maxTokensPerTx = _maxTokensPerTx;
    }

    function setPriceByContract(address contractAddress, uint256 price) public onlyOwner {
        _contractPrices[contractAddress] = price;
    }

    function withdrawBalance() external onlyOwner {
        (bool success,) = payable(msg.sender).call{value: address(this).balance}("");
        if (!success) revert TransferFailed();
    }

    receive() external payable {}

    fallback() external payable {}
}