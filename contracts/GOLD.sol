// SPDX-License-Identifier: MIT LICENSE

pragma solidity ^0.8.0;

/* --- IMPORTS --- */
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Contract: GOLD.sol

contract GOLD is ERC20, Ownable {
    // Mapping from an address to if it can mint/burn
    mapping(address => bool) controllers;

    constructor() ERC20("GOLD", "GOLD") {}

    /**
     * Mints $GOLD to a recipient
     * @param to: the recipient of the $GOLD
     * @param amount: the amount of $GOLD to mint
     */
    function mint(address to, uint256 amount) external {
        require(controllers[msg.sender], "Only controllers can mint");
        _mint(to, amount);
    }

    /**
     * Burns $GOLD from a holder
     * @param from: the holder of the $GOLD
     * @param amount: the amount of $GOLD to burn
     */
    function burn(address from, uint256 amount) external {
        require(controllers[msg.sender], "Only controllers can burn");
        _burn(from, amount);
    }

    /**
     * Enables an address to mint/burn
     * @param controller: the address to enable
     */
    function addController(address controller) external onlyOwner {
        controllers[controller] = true;
    }

    /**
     * Disables an address from minting/burning
     * @param controller: the address to disbale
     */
    function removeController(address controller) external onlyOwner {
        controllers[controller] = false;
    }

    function decimals() public view virtual override returns (uint8) {
        return 9;
    }
}