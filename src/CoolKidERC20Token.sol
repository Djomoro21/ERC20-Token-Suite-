//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Pausable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

/*
 * COOL is COOLKID's native ERC20 token. The most correct way to do this is to create a deploer contract to handle vesting
 * It has a max supply of 100,000,000 COOL.
 */
contract CoolKidToken is ERC20("The Cool token", "COOL"), Ownable(msg.sender), ERC20Pausable {
    uint256 public constant MAX_SUPPLY = 100e6 ether;

    uint256 public s_sellTax = 200; // 2%
    uint256 public s_buyTax = 100; // 1%
    uint256 constant TAX_DENOMINATOR = 10000;
    mapping(address => bool) public s_isExemptFromFee;
    mapping(address => bool) public s_isLPAddress;

    event TaxUpdated(uint256 _newTax, bool isBuyTax);
    event LPAddressListUpdated(address lpAddress, bool isLP);
    event TaxBurned(address from, address to, uint256 taxAmount, bool isBuy);

    constructor() {
        s_isExemptFromFee[address(this)] = true;
        s_isExemptFromFee[msg.sender] = true;

        _mint(address(this), MAX_SUPPLY);
    }

    function burn(uint256 _amount) external {
        _burn(msg.sender, _amount);
    }

    function setTaxes(uint256 _newTax, bool _isBuyTax) external onlyOwner {
        require(_newTax <= 1000, "Tax cannot exceed 10%"); // Max 10% tax

        if (_isBuyTax) {
            s_buyTax = _newTax;
        } else {
            s_sellTax = _newTax;
        }

        emit TaxUpdated(_newTax, _isBuyTax);
    }

    function setExemptFromFee(address _address, bool _isExempt) external onlyOwner {
        require(_address != address(0), "Invalid address");
        s_isExemptFromFee[_address] = _isExempt;
    }

    function setLPAddress(address lpAddress, bool isLP) external onlyOwner {
        require(lpAddress != address(0), "Invalid LP address");
        s_isLPAddress[lpAddress] = isLP;
        emit LPAddressListUpdated(lpAddress, isLP);
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Pausable) {
        // Check if tax should be applied
        bool takeFee = !s_isExemptFromFee[from] && !s_isExemptFromFee[to];

        if (takeFee) {
            uint256 taxAmount = 0;
            bool isBuy = false;

            // Determine if it's a buy or sell
            if (s_isLPAddress[from]) {
                // Buy transaction (from LP to user)
                taxAmount = (value * s_buyTax) / TAX_DENOMINATOR;
                isBuy = true;
            } else if (s_isLPAddress[to]) {
                // Sell transaction (from user to LP)
                taxAmount = (value * s_sellTax) / TAX_DENOMINATOR;
                isBuy = false;
            }

            if (taxAmount > 0) {
                // Burn the tax amount
                super._update(from, address(0), taxAmount);

                // Transfer remaining amount to recipient
                super._update(from, to, value - taxAmount);

                emit TaxBurned(from, to, taxAmount, isBuy);
                return;
            }
        }

        // No tax, normal transfer
        super._update(from, to, value);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
