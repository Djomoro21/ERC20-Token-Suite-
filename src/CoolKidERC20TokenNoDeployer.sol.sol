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
    using SafeERC20 for IERC20;

    struct VestingScheduleGroup {
        uint256 cliff;
        uint256 duration;
        uint256 startTime;
        uint256 percentageOfTotalSupply;
    }

    struct BeneficiaryInfo {
        uint256 beneficiaryPercentage; // Percentage within the category
        uint256 totalClaimed;
        string category;
    }

    mapping(string category => VestingScheduleGroup) public s_vestingSchedules;
    mapping(address beneficiary => BeneficiaryInfo) public s_beneficiaryInfo;
    mapping(string category => uint256 totalBeneficiaryPercentage) public s_totalBeneficiaryPercentagePerCategory;

    IUniswapV2Router02 public immutable i_uniswapV2Router;
    address public immutable i_coolKidWETHPair;
    bool private s_liquidityAdded;

    uint256 public constant MAX_SUPPLY = 100e6 ether;
    uint256 public constant COMMUNITY_REWARDS_SUPPLY = 50e6 ether; // 50% total (5% team + 10% investors)
    uint256 public constant LP_SUPPLY = 15e6 ether; // 15% for initial LP
    uint256 public constant PRESALE_SUPPLY = 20e6 ether; // 20% for initial LP
    uint256 constant ONE_YEAR = 365 days;

    uint256 public s_sellTax = 200; // 2%
    uint256 public s_buyTax = 100; // 1%
    uint256 constant TAX_DENOMINATOR = 10000;
    mapping(address => bool) public s_isExemptFromFee;
    mapping(address => bool) public s_isLPAddress;

    event TaxUpdated(uint256 _newTax, bool isBuyTax);
    event LPAddressListUpdated(address lpAddress, bool isLP);
    event TaxBurned(address from, address to, uint256 taxAmount, bool isBuy);
    event NewVestingAdded(string _category, uint256 _cliff, uint256 _duration, uint256 _startTime, uint256 _percentage);
    event NewBeneficiaryAdded(string _category, address _beneficiary, uint256 _beneficiaryPercentage);
    event VestingClaimed(address beneficiary, string category, uint256 amount);

    error InvalidBeneficiary();
    error NoBeneficiaryInCategory();
    error NoClaimableTokens();
    error VestingAlreadyExists();
    error NoVestingForCategory();
    error MaxCapReached();
    error LiquidityAlreadyAdded();
    error NoETHProvided();

    constructor(address _router, address _treasury, address _presale) payable {
        require(_router != address(0), "Invalid router address");
        require(_treasury != address(0), "Invalid router address");
        
        _mint(address(this), MAX_SUPPLY);

        //Send Community rewards to multisig address
        IERC20(address(this)).safeTransfer(_treasury, COMMUNITY_REWARDS_SUPPLY);
        //Send IDO supply to presale contract address or 
        IERC20(address(this)).safeTransfer(_presale, PRESALE_SUPPLY);

        // Initialize Router
        i_uniswapV2Router = IUniswapV2Router02(_router);
        
        // Create pair
        i_coolKidWETHPair = IUniswapV2Factory(i_uniswapV2Router.factory()).createPair(
            address(this), 
            i_uniswapV2Router.WETH()
        );
        
        s_isExemptFromFee[address(this)] = true;
        s_isExemptFromFee[msg.sender] = true;
        s_isExemptFromFee[i_coolKidWETHPair] = true;
        s_isLPAddress[i_coolKidWETHPair] = true;

        // Add liquidity if ETH provided
        if (msg.value > 0) {
            _addInitialLiquidity(msg.value);
        }

        // Create Vesting Schedule for team (5%, 6 month cliff, 1 year vesting)
        _createVestingSchedule("team", ONE_YEAR / 2, ONE_YEAR, block.timestamp, 5);
        
        // Create Vesting Schedule for investors (10%, 3 month cliff, 1 year vesting)
        _createVestingSchedule("investors", ONE_YEAR / 4, ONE_YEAR, block.timestamp, 10);
    }

    function _addInitialLiquidity(uint256 ethAmount) internal {
        if (s_liquidityAdded) revert LiquidityAlreadyAdded();
        if (ethAmount == 0) revert NoETHProvided();

        // Use LP_SUPPLY (15% of total supply)
        uint256 tokenAmount = LP_SUPPLY;

        // Approve router to spend tokens
        _approve(address(this), address(i_uniswapV2Router), tokenAmount);

        // Add liquidity
        i_uniswapV2Router.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            owner(),
            block.timestamp + 300
        );

        s_liquidityAdded = true;
    }

    function addLiquidityManually() external payable onlyOwner {
        if (s_liquidityAdded) revert LiquidityAlreadyAdded();
        if (msg.value == 0) revert NoETHProvided();
        _addInitialLiquidity(msg.value);
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

    function _createVestingSchedule(
        string memory _category,
        uint256 _cliff,
        uint256 _duration,
        uint256 _startTime,
        uint256 _percentage
    ) internal {
        if (s_vestingSchedules[_category].startTime != 0) revert VestingAlreadyExists();
        require(_percentage > 0 && _percentage <= 100, "Invalid percentage");
        require(_duration > 0, "Invalid duration");

        s_vestingSchedules[_category] = VestingScheduleGroup({
            cliff: _cliff,
            duration: _duration,
            startTime: _startTime,
            percentageOfTotalSupply: _percentage
        });

        emit NewVestingAdded(_category, _cliff, _duration, _startTime, _percentage);
    }

    function addBeneficiaryToVestingCategory(
        string memory _category,
        address _beneficiary,
        uint256 _beneficiaryPercentage
    ) external onlyOwner {
        if (s_vestingSchedules[_category].startTime == 0) revert NoVestingForCategory();
        if (_beneficiary == address(0)) revert InvalidBeneficiary();
        require(_beneficiaryPercentage > 0, "Invalid percentage");
        require(s_beneficiaryInfo[_beneficiary].beneficiaryPercentage == 0, "Already a beneficiary");

        // Check if adding this beneficiary would exceed the category cap
        uint256 newTotal = s_totalBeneficiaryPercentagePerCategory[_category] + _beneficiaryPercentage;
        if (newTotal > 100) revert MaxCapReached();

        s_beneficiaryInfo[_beneficiary] = BeneficiaryInfo({
            beneficiaryPercentage: _beneficiaryPercentage,
            totalClaimed: 0,
            category: _category
        });

        s_totalBeneficiaryPercentagePerCategory[_category] = newTotal;

        emit NewBeneficiaryAdded(_category, _beneficiary, _beneficiaryPercentage);
    }

    function claimVesting() external {
        BeneficiaryInfo storage beneficiary = s_beneficiaryInfo[msg.sender];
        
        if (beneficiary.beneficiaryPercentage == 0) revert NoBeneficiaryInCategory();

        uint256 claimableAmount = _calculateClaimableAmount(msg.sender);
        if (claimableAmount == 0) revert NoClaimableTokens();

        beneficiary.totalClaimed += claimableAmount;

        // Transfer from contract to beneficiary
        super._update(address(this), msg.sender, claimableAmount);

        emit VestingClaimed(msg.sender, beneficiary.category, claimableAmount);
    }

    function _calculateClaimableAmount(address _beneficiary) internal view returns (uint256) {
        BeneficiaryInfo memory beneficiary = s_beneficiaryInfo[_beneficiary];
        
        if (beneficiary.beneficiaryPercentage == 0) return 0;

        VestingScheduleGroup memory schedule = s_vestingSchedules[beneficiary.category];
        
        // Check if cliff period has passed
        if (block.timestamp < schedule.startTime + schedule.cliff) {
            return 0;
        }

        // Calculate total vested amount for this beneficiary
        uint256 totalAllocation = (MAX_SUPPLY * schedule.percentageOfTotalSupply * beneficiary.beneficiaryPercentage) / (100 * 100);

        uint256 vestedAmount;
        
        // Check if vesting period is complete
        if (block.timestamp >= schedule.startTime + schedule.cliff + schedule.duration) {
            vestedAmount = totalAllocation;
        } else {
            // Calculate linear vesting
            uint256 timeFromCliff = block.timestamp - (schedule.startTime + schedule.cliff);
            vestedAmount = (totalAllocation * timeFromCliff) / schedule.duration;
        }

        // Return claimable amount (vested - already claimed)
        return vestedAmount - beneficiary.totalClaimed;
    }

    function getClaimableAmount(address _beneficiary) external view returns (uint256) {
        return _calculateClaimableAmount(_beneficiary);
    }

    function getBeneficiaryInfo(address _beneficiary) external view returns (
        uint256 beneficiaryPercentage,
        uint256 totalClaimed,
        string memory category,
        uint256 claimable
    ) {
        BeneficiaryInfo memory info = s_beneficiaryInfo[_beneficiary];
        return (
            info.beneficiaryPercentage,
            info.totalClaimed,
            info.category,
            _calculateClaimableAmount(_beneficiary)
        );
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    receive() external payable {}
}