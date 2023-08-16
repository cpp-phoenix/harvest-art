// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "ERC1155P/contracts/IERC1155P.sol";

interface IBidTicket is IERC1155P {
    function setURI(uint256 tokenId, string calldata tokenURI) external;

    function mint(address to, uint256 id, uint256 amount, bytes memory data) external;
    function mintBatch(address to, uint256[] calldata ids, uint256[] calldata amounts, bytes memory data) external;

    function burn(address from, uint256 id, uint256 amount) external;
    function burnBatch(address from, uint256[] calldata ids, uint256[] calldata amounts) external;

    function setHarvestContract(address harvestContract_) external;
    function setMarketContract(address marketContract_) external;
}