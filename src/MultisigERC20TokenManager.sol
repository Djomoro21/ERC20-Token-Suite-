//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CoolKidToken} from "./CoolKidERC20Token.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

/**
 * @title TokenManager
 * @author Djomoro
 * @notice Manages CoolKid token deployment, vesting schedules, and liquidity through a multisig governance system
 * @dev Implements multisig proposal system for critical operations including:
 *      - Token deployment and initial distribution
 *      - Liquidity pool creation and management
 *      - Vesting schedule management for team and investors
 *      - Multisig signer management
 */
contract TokenManager is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            CUSTOM ERRORS
    //////////////////////////////////////////////////////////////*/

    error TokenManager__InvalidAddress(address addr, string reason);
    error TokenManager__InvalidValue(uint256 value, string reason);
    error TokenManager__SignerRequired(string reason);
    error TokenManager__AlreadyExists(string reason);
    error TokenManager__InvalidIndex(string reason);
    error TokenManager__ProposalAlreadyExecuted(uint256 propIndex, string reason);
    error TokenManager__InvalidRequiredConfirmationsNumber(uint256 current, uint256 required, string reason);
    error TokenManager__MaxAllocationExceeded(string reason);
    error TokenManager__AlreadyDeployed(string reason);
    error TokenManager__VestedHolderProposalSubmission(address vestedHolderAddr, uint256 vestedHolderShare, string reason);
    error TokenManager__NewSignerProposalSubmission(address _newSigner, string reason);
    error TokenManager__InvalidPercentage(uint256 percentage, string reason);
    error TokenManager__InvaliddurationAfterCliff(uint256 durationAfterCliff, string reason);
    error TokenManager__ProposalNotPending(uint256 propIndex, string reason);

    /*//////////////////////////////////////////////////////////////
                            ENUMS & STRUCTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Types of proposals that can be submitted to the multisig
     * @dev Each proposal type triggers different execution logic
     */
    enum ProposalType {
        DEPLOY_TOKEN,                      // Deploy the CoolKid token and initialize vesting
        ADD_INITIAL_LIQUIDITY,             // Add liquidity to Uniswap pool
        ADD_VESTED_HOLDER,                 // Add a beneficiary to a vesting category
        ADD_SIGNER,                        // Add a new multisig signer
        REMOVE_SIGNER,                     // Remove an existing multisig signer
        CHANGE_REQUIRED_CONFIRMATIONS      // Change the number of required confirmations
    }

    /**
     * @notice Represents a multisig proposal
     * @param propType The type of proposal being made
     * @param value ETH value sent with the proposal (used for liquidity)
     * @param data ABI-encoded data specific to the proposal type
     * @param isExecuted Whether the proposal has been executed
     * @param isCancelled Whether the proposal has been cancelled
     * @param numOfApprovals Current number of signer approvals
     */
    struct Proposal {
        ProposalType propType;
        uint256 value;
        bytes data;
        bool isExecuted;
        bool isCancelled;
        uint256 numOfApprovals;
    }

    /**
     * @notice Defines a vesting schedule for a category (e.g., "team", "investors")
     * @param cliff Period before any tokens can be claimed
     * @param durationAfterCliff Period over which tokens vest linearly after cliff
     * @param startTime Timestamp when vesting begins
     * @param vestingGroupshareInTotalSupply Percentage of total supply allocated to this category
     * @param vestedHoldersShareCount Sum of all beneficiary shares in this category
     */
    struct VestingScheduleGroup {
        uint256 cliff;
        uint256 durationAfterCliff;
        uint256 startTime;
        uint256 vestingGroupshareInTotalSupply;
        uint256 vestedHoldersShareCount;
    }

    /**
     * @notice Information about an individual vesting beneficiary
     * @param beneficiaryShare Percentage of the category allocation this beneficiary receives
     * @param totalClaimed Total tokens already claimed by this beneficiary
     * @param category The vesting category this beneficiary belongs to
     */
    struct BeneficiaryInfo {
        uint256 beneficiaryShare;
        uint256 totalClaimed;
        string category;
    }

    /*//////////////////////////////////////////////////////////////
                        STATE VARIABLES - MULTISIG
    //////////////////////////////////////////////////////////////*/

    /// @notice Array of current multisig signers
    address[] private s_signers;
    
    /// @notice Array of all proposals (pending, executed, and cancelled)
    Proposal[] private proposals;
    
    /// @notice Minimum number of signers required (must always have at least 1)
    uint256 private constant MIN_NUM_SIGNER = 1;
    
    /// @notice Number of approvals required to execute a proposal
    uint256 private s_numRequiredConfirmations;
    
    /// @notice Maps address to whether they are an authorized signer
    mapping(address => bool) private s_isSigner;
    
    /// @notice Tracks which signers have confirmed each proposal
    /// @dev proposalIndex => (signerAddress => hasConfirmed)
    mapping(uint256 propIndex => mapping(address signer => bool hasConfirmed)) private hasConfirmed;

    /*//////////////////////////////////////////////////////////////
                        STATE VARIABLES - VESTING
    //////////////////////////////////////////////////////////////*/

    /// @notice Constant representing one year in seconds (365 days)
    uint256 private constant ONE_YEAR = 365 days;
    
    /// @notice Maps beneficiary addresses to their vesting information
    mapping(address beneficiary => BeneficiaryInfo) private s_vestedHolderInfo;
    
    /// @notice Maps category names to their vesting schedule configuration
    mapping(string category => VestingScheduleGroup) private s_vestingSchedules;

    /*//////////////////////////////////////////////////////////////
                        STATE VARIABLES - TOKEN
    //////////////////////////////////////////////////////////////*/

    /// @notice The CoolKid token contract instance
    CoolKidToken private s_coolKidToken;
    
    /// @notice Total supply of tokens (set at deployment)
    uint256 private s_tokenMaxSupply;
    
    /// @notice Address that receives community rewards and LP tokens
    address private immutable i_treasury;
    
    /// @notice Address of the presale contract that receives presale allocation
    address private immutable i_presaleContract;
    
    /// @notice Whether the token has been deployed
    bool private s_isTokenDeployed;

    /*//////////////////////////////////////////////////////////////
                    STATE VARIABLES - LIQUIDITY POOL
    //////////////////////////////////////////////////////////////*/

    /// @notice Address of the Uniswap V2 Router
    address private immutable i_router;
    
    /// @notice Uniswap V2 Router contract interface
    IUniswapV2Router02 private i_uniswapV2Router;
    
    /// @notice Address of the CoolKid/WETH Uniswap pair
    address private s_coolKidWETHPair;
    
    /// @notice Whether initial liquidity has been added
    bool private s_liquidityAdded;

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Restricts function access to authorized signers only
     */
    modifier onlySigner() {
        if (!s_isSigner[msg.sender]) {
            revert TokenManager__SignerRequired("Caller is not an authorized signer");
        }
        _;
    }

    /**
     * @notice Validates that a proposal exists
     * @param propIndex The index of the proposal to check
     */
    modifier proposalExists(uint256 propIndex) {
        if (propIndex >= proposals.length) {
            revert TokenManager__InvalidIndex("Invalid proposal index, out of bound");
        }
        _;
    }

    /**
     * @notice Validates that a proposal has not been executed or cancelled
     * @param propIndex The index of the proposal to check
     */
    modifier proposalExecuted(uint256 propIndex) {
        if (proposals[propIndex].isExecuted) {
            revert TokenManager__ProposalAlreadyExecuted(propIndex, "proposal already executed");
        }
        if (proposals[propIndex].isCancelled) {
            revert TokenManager__ProposalNotPending(propIndex, "proposal has been cancelled");
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    event SubmitTransaction(address indexed proposalSubmitter, ProposalType propType);
    event NewVestingAdded(string _category, uint256 _cliff, uint256 _durationAfterCliff, uint256 _startTime, uint256 _percentage);
    event NewVestedHolderAdded(string _category, address _vestedHolder, uint256 _vestedHolderShare);
    event VestingClaimed(address beneficiary, string category, uint256 amount);
    event SignerAdded(address newSigner);
    event RequiredConfirmationsNumChanged(uint256 oldNum, uint256 newNum);
    event SignerRemoved(address signer);
    event ProposalCancelled(uint256 indexed propIndex, address indexed canceller);

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the TokenManager with multisig signers and external contract addresses
     * @param _signers Array of initial signer addresses
     * @param _numOfConfirmations Number of confirmations required to execute proposals
     * @param _router Address of the Uniswap V2 Router
     * @param _treasury Address that will receive community rewards and LP tokens
     * @param _presaleContract Address of the presale contract
     * @dev Validates all inputs and ensures no duplicate signers
     */
    constructor(
        address[] memory _signers,
        uint256 _numOfConfirmations,
        address _router,
        address _treasury,
        address _presaleContract
    ) {
        // Validate signers array is not empty
        if (_signers.length == 0) {
            revert TokenManager__SignerRequired("Need at least 1 signer. The provided signers array is empty");
        }
        
        // Validate number of confirmations is reasonable
        if (_numOfConfirmations > _signers.length || _numOfConfirmations == 0) {
            revert TokenManager__InvalidRequiredConfirmationsNumber(
                _numOfConfirmations,
                _signers.length,
                "required confirmations must be between 1 and number of signers"
            );
        }
        
        s_numRequiredConfirmations = _numOfConfirmations;
        
        // Initialize signers and check for duplicates
        for (uint256 i = 0; i < _signers.length; i++) {
            address signer = _signers[i];
            
            if (signer == address(0)) {
                revert TokenManager__InvalidAddress(signer, "Signer address cannot be zero address");
            }
            if (s_isSigner[signer]) {
                revert TokenManager__AlreadyExists("Duplicate signer in initialization");
            }
            
            s_isSigner[_signers[i]] = true;
            s_signers.push(_signers[i]);
        }

        // Set immutable external contract addresses
        i_router = _router;
        i_treasury = _treasury;
        i_presaleContract = _presaleContract;
    }

    /*//////////////////////////////////////////////////////////////
                    PROPOSAL SUBMISSION FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Submits a basic proposal (DEPLOY_TOKEN, ADD_INITIAL_LIQUIDITY)
     * @param propType The type of proposal to submit
     * @dev ETH can be sent with this function for liquidity proposals
     * @dev Automatically initializes confirmation tracking for all signers
     */
    function submitProposal(ProposalType propType) external payable onlySigner {
        uint256 propIndex = proposals.length;

        proposals.push(
            Proposal({
                propType: propType,
                value: msg.value,
                data: "",
                isExecuted: false,
                isCancelled: false,
                numOfApprovals: 0
            })
        );

        // Initialize confirmation status for all signers
        for (uint256 i = 0; i < s_signers.length; i++) {
            hasConfirmed[propIndex][s_signers[i]] = false;
        }

        emit SubmitTransaction(msg.sender, propType);
    }

    /**
     * @notice Submits a proposal to add a vested holder to an existing vesting category
     * @param _category The vesting category (must already exist, e.g., "team" or "investors")
     * @param _vestedHolder Address of the beneficiary to add
     * @param _vestedHolderShare Percentage share of the category allocation (0-100)
     * @dev Validates that category exists and share is within bounds
     */
    function submitVestedHolderProposal(
        string memory _category,
        address _vestedHolder,
        uint256 _vestedHolderShare
    ) external payable onlySigner {
        // Validate vesting category exists
        if (s_vestingSchedules[_category].startTime == 0) {
            revert TokenManager__InvalidIndex("vesting schedule not found for this category");
        }
        
        // Validate beneficiary address and share
        if (_vestedHolder == address(0) || _vestedHolderShare == 0) {
            revert TokenManager__VestedHolderProposalSubmission(
                _vestedHolder,
                _vestedHolderShare,
                "Invalid vested holder address or share. Neither cannot be zero"
            );
        }
        
        // Validate share percentage
        if (_vestedHolderShare > 100) {
            revert TokenManager__InvalidPercentage(_vestedHolderShare, "Vested holder share cannot exceed 100%");
        }

        // Encode proposal data
        bytes memory data = abi.encode(_category, _vestedHolder, _vestedHolderShare);
        uint256 propIndex = proposals.length;

        proposals.push(
            Proposal({
                propType: ProposalType.ADD_VESTED_HOLDER,
                value: msg.value,
                data: data,
                isExecuted: false,
                isCancelled: false,
                numOfApprovals: 0
            })
        );

        // Initialize confirmation status
        for (uint256 i = 0; i < s_signers.length; i++) {
            hasConfirmed[propIndex][s_signers[i]] = false;
        }

        emit SubmitTransaction(msg.sender, ProposalType.ADD_VESTED_HOLDER);
    }

    /**
     * @notice Submits a proposal to add a new signer to the multisig
     * @param _newSigner Address of the new signer to add
     * @param _newRequiredNumConfirmation New required confirmations count after adding signer
     * @dev New confirmation count must account for the increased total signer count
     */
    function submitAddNewSignerProposal(address _newSigner, uint256 _newRequiredNumConfirmation)
        public
        payable
        onlySigner
    {
        // Validate new signer address
        if (_newSigner == address(0) || s_isSigner[_newSigner]) {
            revert TokenManager__NewSignerProposalSubmission(
                _newSigner,
                "Invalid address(zero address) or new signer already exists"
            );
        }
        
        // Validate new required confirmations
        if (_newRequiredNumConfirmation == 0 || _newRequiredNumConfirmation > s_signers.length + 1) {
            revert TokenManager__InvalidRequiredConfirmationsNumber(
                _newRequiredNumConfirmation,
                s_signers.length + 1,
                "required confirmations must be between 1 and new total signers"
            );
        }

        bytes memory data = abi.encode(_newSigner, _newRequiredNumConfirmation);
        uint256 propIndex = proposals.length;

        proposals.push(
            Proposal({
                propType: ProposalType.ADD_SIGNER,
                value: msg.value,
                data: data,
                isExecuted: false,
                isCancelled: false,
                numOfApprovals: 0
            })
        );

        for (uint256 i = 0; i < s_signers.length; i++) {
            hasConfirmed[propIndex][s_signers[i]] = false;
        }

        emit SubmitTransaction(msg.sender, ProposalType.ADD_SIGNER);
    }

    /**
     * @notice Submits a proposal to remove a signer from the multisig
     * @param _signerToRemove Address of the signer to remove
     * @dev Cannot remove the last signer (minimum 1 required)
     * @dev Required confirmations will auto-adjust if necessary
     */
    function submitRemoveSignerProposal(address _signerToRemove) public payable onlySigner {
        // Validate signer exists
        if (!s_isSigner[_signerToRemove]) {
            revert TokenManager__InvalidIndex("Signer to remove does not exist");
        }
        
        // Prevent removing last signer
        if (s_signers.length <= MIN_NUM_SIGNER) {
            revert TokenManager__SignerRequired("cannot remove last signer");
        }

        bytes memory data = abi.encode(_signerToRemove);
        uint256 propIndex = proposals.length;

        proposals.push(
            Proposal({
                propType: ProposalType.REMOVE_SIGNER,
                value: msg.value,
                data: data,
                isExecuted: false,
                isCancelled: false,
                numOfApprovals: 0
            })
        );

        for (uint256 i = 0; i < s_signers.length; i++) {
            hasConfirmed[propIndex][s_signers[i]] = false;
        }

        emit SubmitTransaction(msg.sender, ProposalType.REMOVE_SIGNER);
    }

    /**
     * @notice Submits a proposal to change the required number of confirmations
     * @param _newRequired New number of required confirmations
     * @dev Must be between 1 and current number of signers
     */
    function submitRequiredConfirmationsChangeProposal(uint256 _newRequired) public payable onlySigner {
        // Validate new required confirmations
        if (_newRequired == 0 || _newRequired > s_signers.length) {
            revert TokenManager__InvalidRequiredConfirmationsNumber(
                _newRequired,
                s_signers.length,
                "required confirmations must be between 1 and current number of signers"
            );
        }

        bytes memory data = abi.encode(_newRequired);
        uint256 propIndex = proposals.length;

        proposals.push(
            Proposal({
                propType: ProposalType.CHANGE_REQUIRED_CONFIRMATIONS,
                value: msg.value,
                data: data,
                isExecuted: false,
                isCancelled: false,
                numOfApprovals: 0
            })
        );

        for (uint256 i = 0; i < s_signers.length; i++) {
            hasConfirmed[propIndex][s_signers[i]] = false;
        }

        emit SubmitTransaction(msg.sender, ProposalType.CHANGE_REQUIRED_CONFIRMATIONS);
    }

    /*//////////////////////////////////////////////////////////////
                    PROPOSAL MANAGEMENT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Approves a pending proposal
     * @param propIndex Index of the proposal to approve
     * @dev Automatically executes the proposal if required confirmations are reached
     * @dev Prevents double-voting by the same signer
     */
    function approveProposal(uint256 propIndex)
        public
        onlySigner
        proposalExists(propIndex)
        proposalExecuted(propIndex)
    {
        // Prevent double approval
        if (hasConfirmed[propIndex][msg.sender]) {
            revert TokenManager__AlreadyExists("Signer has already confirmed this proposal");
        }
        
        hasConfirmed[propIndex][msg.sender] = true;
        proposals[propIndex].numOfApprovals++;
        
        // Auto-execute if threshold reached
        if (proposals[propIndex].numOfApprovals == s_numRequiredConfirmations) {
            executeProposal(propIndex);
        }
    }

    /**
     * @notice Cancels a pending proposal and refunds any ETH
     * @param propIndex Index of the proposal to cancel
     * @dev Only pending proposals can be cancelled
     * @dev Refunds ETH to the canceller if any was sent with the proposal
     */
    function cancelProposal(uint256 propIndex)
        public
        onlySigner
        proposalExists(propIndex)
        proposalExecuted(propIndex)
    {
        proposals[propIndex].isCancelled = true;

        // Refund ETH if any was sent with the proposal
        if (proposals[propIndex].value > 0) {
            (bool success,) = msg.sender.call{value: proposals[propIndex].value}("");
            if (!success) {
                revert TokenManager__InvalidValue(proposals[propIndex].value, "Failed to refund ETH");
            }
        }

        emit ProposalCancelled(propIndex, msg.sender);
    }

    /**
     * @notice Executes a proposal that has reached the required confirmations
     * @param propIndex Index of the proposal to execute
     * @dev Routes to appropriate internal function based on proposal type
     * @dev Can only be executed once and requires sufficient approvals
     */
    function executeProposal(uint256 propIndex)
        public
        onlySigner
        proposalExists(propIndex)
        proposalExecuted(propIndex)
    {
        Proposal storage proposal = proposals[propIndex];
        ProposalType propType = proposal.propType;

        // Verify sufficient approvals
        if (proposal.numOfApprovals < s_numRequiredConfirmations) {
            revert TokenManager__InvalidRequiredConfirmationsNumber(
                proposal.numOfApprovals,
                s_numRequiredConfirmations,
                "not enough approvals to execute proposal"
            );
        }

        // Route to appropriate execution function based on type
        if (propType == ProposalType.DEPLOY_TOKEN) {
            _deployToken(proposal.value);
            proposal.isExecuted = true;
            return;
            
        } else if (propType == ProposalType.ADD_INITIAL_LIQUIDITY) {
            _addInitialLiquidity(proposal.value);
            proposal.isExecuted = true;
            return;
            
        } else if (propType == ProposalType.ADD_VESTED_HOLDER) {
            (string memory _category, address _vestedHolder, uint256 _share) =
                abi.decode(proposal.data, (string, address, uint256));
            _addHolderToVestingCategory(_category, _vestedHolder, _share);
            proposal.isExecuted = true;
            return;
            
        } else if (propType == ProposalType.ADD_SIGNER) {
            (address _signer, uint256 numConfirmations) = abi.decode(proposal.data, (address, uint256));
            _addSigner(_signer, numConfirmations);
            proposal.isExecuted = true;
            return;
            
        } else if (propType == ProposalType.REMOVE_SIGNER) {
            address _signer = abi.decode(proposal.data, (address));
            _removeSigner(_signer);
            proposal.isExecuted = true;
            return;
            
        } else if (propType == ProposalType.CHANGE_REQUIRED_CONFIRMATIONS) {
            uint256 _requiredConfirmations = abi.decode(proposal.data, (uint256));
            _changeRequiredConfirmations(_requiredConfirmations);
            proposal.isExecuted = true;
            return;
        }

        revert TokenManager__InvalidIndex("Unknown proposal type");
    }

    /*//////////////////////////////////////////////////////////////
                    TOKEN DEPLOYMENT & LIQUIDITY
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploys the CoolKid token and initializes distribution
     * @param ethAmount ETH to add to initial liquidity (optional, can be 0)
     * @dev Allocations: 60% treasury, 10% presale, 15% liquidity, 5% team, 10% investors
     * @dev Creates two vesting schedules: team (6mo cliff, 12mo vest) and investors (3mo cliff, 12mo vest)
     * @dev Can only be called once through proposal execution
     */
    function _deployToken(uint256 ethAmount) internal {
        // Validate immutable addresses
        if (i_router == address(0)) {
            revert TokenManager__InvalidAddress(i_router, "Invalid(zero) router address");
        }
        if (i_treasury == address(0)) {
            revert TokenManager__InvalidAddress(i_treasury, "Invalid(zero) treasury address");
        }
        if (i_presaleContract == address(0)) {
            revert TokenManager__InvalidAddress(i_presaleContract, "Invalid(zero) presaleContract address");
        }
        
        // Prevent double deployment
        if (s_isTokenDeployed) {
            revert TokenManager__AlreadyDeployed("Token already deployed");
        }

        // Deploy token (mints all supply to this contract)
        s_coolKidToken = new CoolKidToken();
        s_tokenMaxSupply = IERC20(s_coolKidToken).balanceOf(address(this));

        // Transfer 60% to treasury for community rewards
        IERC20(s_coolKidToken).safeTransfer(i_treasury, (s_tokenMaxSupply * 60) / 100);
        
        // Transfer 10% to presale contract
        IERC20(s_coolKidToken).safeTransfer(i_presaleContract, (s_tokenMaxSupply * 10) / 100);

        // Initialize Uniswap integration
        i_uniswapV2Router = IUniswapV2Router02(i_router);

        // Create CoolKid/WETH pair
        s_coolKidWETHPair =
            IUniswapV2Factory(i_uniswapV2Router.factory()).createPair(address(s_coolKidToken), i_uniswapV2Router.WETH());

        // Configure token fees for the LP
        s_coolKidToken.setExemptFromFee(s_coolKidWETHPair, true);
        s_coolKidToken.setLPAddress(s_coolKidWETHPair, true);

        // Add initial liquidity if ETH provided
        if (ethAmount > 0) {
            _addInitialLiquidity(ethAmount);
        }

        // Create vesting schedules
        // Team: 6 month cliff, then 1 year linear vesting, 5% of total supply
        _createVestingSchedule("team", ONE_YEAR / 2, ONE_YEAR, block.timestamp, 5);
        
        // Investors: 3 month cliff, then 1 year linear vesting, 10% of total supply
        _createVestingSchedule("investors", ONE_YEAR / 4, ONE_YEAR, block.timestamp, 10);

        s_isTokenDeployed = true;
    }

    /**
     * @notice Adds initial liquidity to the Uniswap pool
     * @param ethAmount Amount of ETH to pair with tokens
     * @dev Uses 15% of total token supply for liquidity
     * @dev LP tokens are sent to treasury
     * @dev Can only be called once, after token deployment
     */
    function _addInitialLiquidity(uint256 ethAmount) internal {
        // Validate token is deployed
        if (!s_isTokenDeployed) {
            revert TokenManager__AlreadyDeployed("Token must be deployed before adding liquidity");
        }
        
        // Prevent double liquidity addition
        if (s_liquidityAdded) {
            revert TokenManager__AlreadyDeployed("liquidity has already been added");
        }
        
        // Validate ETH amount
        if (ethAmount == 0) {
            revert TokenManager__InvalidValue(0, "ETH amount for liquidity cannot be zero");
        }

        // Calculate token amount (15% of total supply)
        uint256 tokenAmount = (s_tokenMaxSupply * 15) / 100;

        // Approve router to spend tokens
        IERC20(s_coolKidToken).approve(address(i_uniswapV2Router), tokenAmount);

        // Add liquidity (LP tokens go to treasury, no minimum amounts, 5min deadline)
        i_uniswapV2Router.addLiquidityETH{value: ethAmount}(
            address(s_coolKidToken),
            tokenAmount,
            0, // No minimum tokens
            0, // No minimum ETH
            i_treasury, // LP tokens sent here
            block.timestamp + 300 // 5 minute deadline
        );

        s_liquidityAdded = true;
    }

    /*//////////////////////////////////////////////////////////////
                        VESTING MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Creates a new vesting schedule category
     * @param _category Name of the category (e.g., "team", "investors")
     * @param _cliff Duration before any tokens can be claimed
     * @param _durationAfterCliff Duration of linear vesting after cliff ends
     * @param _startTime Timestamp when vesting begins
     * @param _percentageShare Percentage of total supply allocated to this category (0-100)
     * @dev Total vesting period = cliff + durationAfterCliff
     * @dev Category names must be unique
     */
    function _createVestingSchedule(
        string memory _category,
        uint256 _cliff,
        uint256 _durationAfterCliff,
        uint256 _startTime,
        uint256 _percentageShare
    ) internal {
        // Prevent duplicate categories
        if (s_vestingSchedules[_category].startTime != 0) {
            revert TokenManager__AlreadyExists("Vesting schedule already exists for this category");
        }
        
        // Validate percentage
        if (_percentageShare == 0 || _percentageShare > 100) {
            revert TokenManager__InvalidPercentage(_percentageShare, "Invalid percentage");
        }
        
        // Validate duration
        if (_durationAfterCliff == 0) {
            revert TokenManager__InvaliddurationAfterCliff(_durationAfterCliff, "Invalid durationAfterCliff");
        }

        // Create the vesting schedule
        s_vestingSchedules[_category] = VestingScheduleGroup({
            cliff: _cliff,
            durationAfterCliff: _durationAfterCliff,
            startTime: _startTime,
            vestingGroupshareInTotalSupply: _percentageShare,
            vestedHoldersShareCount: 0
        });

        emit NewVestingAdded(_category, _cliff, _durationAfterCliff, _startTime, _percentageShare);
    }

    /**
     * @notice Adds a beneficiary to an existing vesting category
     * @param _category The vesting category to add beneficiary to
     * @param _vestedHolder Address of the beneficiary
     * @param _vestedHolderShare Percentage of category allocation for this beneficiary (0-100)
     * @dev Total allocated shares in category cannot exceed category's total allocation
     * @dev Each address can only be added once (cannot have multiple vesting allocations)
     */
    function _addHolderToVestingCategory(string memory _category, address _vestedHolder, uint256 _vestedHolderShare)
        internal
    {
        // Prevent duplicate beneficiaries
        if (s_vestedHolderInfo[_vestedHolder].beneficiaryShare != 0) {
            revert TokenManager__AlreadyExists("Beneficiary already has a vesting allocation");
        }

        // Check if adding this share would exceed category cap
        uint256 newTotal = s_vestingSchedules[_category].vestedHoldersShareCount + _vestedHolderShare;
        if (newTotal > s_vestingSchedules[_category].vestingGroupshareInTotalSupply) {
            revert TokenManager__MaxAllocationExceeded("Vesting group allocation will exceed cap with this share amount");
        }

        // Add beneficiary
        s_vestedHolderInfo[_vestedHolder] =
            BeneficiaryInfo({beneficiaryShare: _vestedHolderShare, totalClaimed: 0, category: _category});

        // Update category's allocated shares
        s_vestingSchedules[_category].vestedHoldersShareCount = newTotal;

        emit NewVestedHolderAdded(_category, _vestedHolder, _vestedHolderShare);
    }

    /**
     * @notice Allows beneficiaries to claim their vested tokens
     * @dev Protected against reentrancy
     * @dev Automatically calculates claimable amount based on time elapsed
     * @dev Reverts if no tokens are available to claim
     */
    function claimVesting() external nonReentrant {
        BeneficiaryInfo storage beneficiary = s_vestedHolderInfo[msg.sender];

        // Validate caller is a beneficiary
        if (beneficiary.beneficiaryShare == 0) {
            revert TokenManager__InvalidIndex("caller is not a registered beneficiary for this vesting group");
        }

        // Calculate claimable amount
        uint256 claimableAmount = _calculateClaimableAmount(msg.sender);
        if (claimableAmount == 0) {
            revert TokenManager__InvalidValue(0, "no tokens available to claim");
        }

        // Update claimed amount
        beneficiary.totalClaimed += claimableAmount;

        // Transfer tokens
        IERC20(s_coolKidToken).safeTransfer(msg.sender, claimableAmount);

        emit VestingClaimed(msg.sender, beneficiary.category, claimableAmount);
    }

    /**
     * @notice Calculates the amount of tokens a beneficiary can currently claim
     * @param _vestedHolder Address of the beneficiary
     * @return Amount of tokens available to claim (already accounts for previously claimed tokens)
     * @dev Vesting logic:
     *      - Before cliff: 0 tokens available
     *      - After cliff, before end: Linear vesting over durationAfterCliff
     *      - After end: All tokens available
     */
    function _calculateClaimableAmount(address _vestedHolder) internal view returns (uint256) {
        BeneficiaryInfo memory beneficiary = s_vestedHolderInfo[_vestedHolder];

        // Return 0 if not a beneficiary
        if (beneficiary.beneficiaryShare == 0) return 0;

        VestingScheduleGroup memory schedule = s_vestingSchedules[beneficiary.category];

        // Check if cliff period has passed
        if (block.timestamp < schedule.startTime + schedule.cliff) {
            return 0;
        }

        // Calculate total allocation for this beneficiary
        // Formula: (totalSupply * categoryPercentage * beneficiaryPercentage) / (100 * 100)
        uint256 totalAllocation =
            (s_tokenMaxSupply * schedule.vestingGroupshareInTotalSupply * beneficiary.beneficiaryShare) / (100 * 100);

        uint256 vestedAmount;

        // Check if vesting period has fully elapsed
        if (block.timestamp >= schedule.startTime + schedule.cliff + schedule.durationAfterCliff) {
            // All tokens are vested
            vestedAmount = totalAllocation;
        } else {
            // Calculate linear vesting from cliff end to duration end
            uint256 timeFromCliff = block.timestamp - (schedule.startTime + schedule.cliff);
            vestedAmount = (totalAllocation * timeFromCliff) / schedule.durationAfterCliff;
        }

        // Return vested amount minus what's already been claimed
        return vestedAmount - beneficiary.totalClaimed;
    }

    /*//////////////////////////////////////////////////////////////
                        MULTISIG MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Adds a new signer to the multisig
     * @param _newSigner Address of the new signer
     * @param _newRequiredNumConfirmation New required confirmations count
     * @dev Updates required confirmations if different from current
     */
    function _addSigner(address _newSigner, uint256 _newRequiredNumConfirmation) private {
        s_signers.push(_newSigner);
        s_isSigner[_newSigner] = true;

        emit SignerAdded(_newSigner);

        // Update required confirmations if changed
        if (s_numRequiredConfirmations != _newRequiredNumConfirmation) {
            uint256 oldRequired = s_numRequiredConfirmations;
            s_numRequiredConfirmations = _newRequiredNumConfirmation;
            emit RequiredConfirmationsNumChanged(oldRequired, _newRequiredNumConfirmation);
        }
    }

    /**
     * @notice Removes a signer from the multisig
     * @param _signerToRemove Address of the signer to remove
     * @dev Uses swap-and-pop pattern for gas efficiency
     * @dev Automatically reduces required confirmations if needed
     */
    function _removeSigner(address _signerToRemove) private {
        // Find and remove signer (swap with last element and pop)
        for (uint256 i = 0; i < s_signers.length; i++) {
            if (s_signers[i] == _signerToRemove) {
                s_signers[i] = s_signers[s_signers.length - 1];
                s_signers.pop();
                break;
            }
        }

        s_isSigner[_signerToRemove] = false;

        // Reduce required confirmations if it exceeds new signer count
        uint256 newSignersLength = s_signers.length;
        if (s_numRequiredConfirmations > newSignersLength) {
            uint256 oldRequired = s_numRequiredConfirmations;
            s_numRequiredConfirmations = newSignersLength;
            emit RequiredConfirmationsNumChanged(oldRequired, newSignersLength);
        }

        emit SignerRemoved(_signerToRemove);
    }

    /**
     * @notice Changes the number of required confirmations
     * @param _newRequired New required confirmations count
     */
    function _changeRequiredConfirmations(uint256 _newRequired) private {
        uint256 oldRequired = s_numRequiredConfirmations;
        s_numRequiredConfirmations = _newRequired;
        emit RequiredConfirmationsNumChanged(oldRequired, _newRequired);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the current list of signers
     * @return Array of signer addresses
     */
    function getSigners() public view returns (address[] memory) {
        return s_signers;
    }

    /**
     * @notice Returns the current required number of confirmations
     * @return Required confirmations count
     */
    function getNumOfRequiredConfirmations() public view returns (uint256) {
        return s_numRequiredConfirmations;
    }

    /**
     * @notice Checks if an address is an authorized signer
     * @param _addr Address to check
     * @return True if address is a signer
     */
    function checkSigner(address _addr) public view returns (bool) {
        return s_isSigner[_addr];
    }

    /**
     * @notice Retrieves pending proposals with pagination
     * @param offset Starting index for pagination
     * @param limit Maximum number of proposals to return
     * @return _pendingProposals Array of pending proposals
     * @return _indices Array of proposal indices in storage
     * @return total Total count of pending proposals
     */
    function getPendingProposalsWithIndices(uint256 offset, uint256 limit)
        public
        view
        returns (Proposal[] memory _pendingProposals, uint256[] memory _indices, uint256 total)
    {
        uint256 propLength = proposals.length;
        uint256 pendingCount = 0;

        // Count pending proposals
        for (uint256 i = 0; i < propLength;) {
            if (!proposals[i].isExecuted && !proposals[i].isCancelled) {
                unchecked {
                    ++pendingCount;
                }
            }
            unchecked {
                ++i;
            }
        }

        total = pendingCount;

        // Calculate pagination bounds
        uint256 end = offset + limit;
        if (end > pendingCount) {
            end = pendingCount;
        }

        uint256 returnSize = 0;
        if (offset < pendingCount) {
            returnSize = end - offset;
        }

        // Initialize return arrays
        _pendingProposals = new Proposal[](returnSize);
        _indices = new uint256[](returnSize);

        uint256 currentIndex = 0;
        uint256 returnIndex = 0;

        // Populate return arrays with paginated results
        for (uint256 i = 0; i < propLength && returnIndex < returnSize;) {
            if (!proposals[i].isExecuted && !proposals[i].isCancelled) {
                if (currentIndex >= offset) {
                    _pendingProposals[returnIndex] = proposals[i];
                    _indices[returnIndex] = i;
                    unchecked {
                        ++returnIndex;
                    }
                }
                unchecked {
                    ++currentIndex;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Retrieves executed proposals with pagination
     * @param offset Starting index for pagination
     * @param limit Maximum number of proposals to return
     * @return _executedProposals Array of executed proposals
     * @return _indices Array of proposal indices in storage
     * @return total Total count of executed proposals
     */
    function getExecutedProposalsHistoryWithIndices(uint256 offset, uint256 limit)
        public
        view
        returns (Proposal[] memory _executedProposals, uint256[] memory _indices, uint256 total)
    {
        uint256 propLength = proposals.length;
        uint256 executedCount = 0;

        // Count executed proposals
        for (uint256 i = 0; i < propLength;) {
            if (proposals[i].isExecuted) {
                unchecked {
                    ++executedCount;
                }
            }
            unchecked {
                ++i;
            }
        }

        total = executedCount;

        // Calculate pagination bounds
        uint256 end = offset + limit;
        if (end > executedCount) {
            end = executedCount;
        }

        uint256 returnSize = 0;
        if (offset < executedCount) {
            returnSize = end - offset;
        }

        // Initialize return arrays
        _executedProposals = new Proposal[](returnSize);
        _indices = new uint256[](returnSize);

        uint256 currentIndex = 0;
        uint256 returnIndex = 0;

        // Populate return arrays with paginated results
        for (uint256 i = 0; i < propLength && returnIndex < returnSize;) {
            if (proposals[i].isExecuted) {
                if (currentIndex >= offset) {
                    _executedProposals[returnIndex] = proposals[i];
                    _indices[returnIndex] = i;
                    unchecked {
                        ++returnIndex;
                    }
                }
                unchecked {
                    ++currentIndex;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Returns the number of confirmations for a proposal
     * @param _propIndex Index of the proposal
     * @return _numConfirmations Current confirmation count
     */
    function getNumOfConfirmations(uint256 _propIndex)
        public
        view
        proposalExists(_propIndex)
        returns (uint256 _numConfirmations)
    {
        _numConfirmations = proposals[_propIndex].numOfApprovals;
    }

    /**
     * @notice Returns the total number of proposals
     * @return Total proposal count (includes pending, executed, and cancelled)
     */
    function getProposalCount() public view returns (uint256) {
        return proposals.length;
    }

    /**
     * @notice Checks if a signer has confirmed a specific proposal
     * @param propIndex Index of the proposal
     * @param signer Address of the signer to check
     * @return True if signer has confirmed the proposal
     */
    function isConfirmedBy(uint256 propIndex, address signer)
        public
        view
        proposalExists(propIndex)
        returns (bool)
    {
        return hasConfirmed[propIndex][signer];
    }

    /**
     * @notice Returns the details of a specific proposal
     * @param _propIndex Index of the proposal
     * @return Complete proposal struct
     */
    function getProposal(uint256 _propIndex) public view proposalExists(_propIndex) returns (Proposal memory) {
        return proposals[_propIndex];
    }

    /**
     * @notice Returns the amount of tokens a beneficiary can currently claim
     * @param _vestedHolder Address of the beneficiary
     * @return Claimable token amount
     */
    function getClaimableAmount(address _vestedHolder) external view returns (uint256) {
        return _calculateClaimableAmount(_vestedHolder);
    }

    /**
     * @notice Returns comprehensive information about a beneficiary's vesting
     * @param _vestedHolder Address of the beneficiary
     * @return beneficiaryPercentage Their percentage share of the category
     * @return totalClaimed Total tokens already claimed
     * @return category The vesting category they belong to
     * @return claimable Currently claimable token amount
     */
    function getBeneficiaryInfo(address _vestedHolder)
        external
        view
        returns (uint256 beneficiaryPercentage, uint256 totalClaimed, string memory category, uint256 claimable)
    {
        BeneficiaryInfo memory info = s_vestedHolderInfo[_vestedHolder];
        return (info.beneficiaryShare, info.totalClaimed, info.category, _calculateClaimableAmount(_vestedHolder));
    }

    /*//////////////////////////////////////////////////////////////
                            RECEIVE FUNCTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Allows contract to receive ETH
     * @dev Required for receiving ETH with proposals
     */
    receive() external payable {}
}