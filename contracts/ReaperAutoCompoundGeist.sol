// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./interfaces/IAToken.sol";
import "./interfaces/IGeistStaking.sol";
import "./interfaces/ILendingPool.sol";
import "./interfaces/ILendingPoolAddressesProvider.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IUniswapRouterETH.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

/**
 * @dev Implementation of a strategy to get yields from staking Geist tokens at Geist Finance.
 * Geist is a lending-borrowing protocol (fork of Aave) where users can stake Geist tokens to earn platform fees.
 *
 * This strategy deposits the Geist tokens it receives from the vault into Geist's staking contract.
 * Rewards from staking Geist (a variety of gTokens) are farmed every few minutes, swapped for Geist, and staked.
 * 
 * Expect the amount of Geist tokens you have deposited to grow over time.
 */
contract ReaperAutoCompoundGeist is Ownable, Pausable {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /**
     * @dev Tokens Used:
     * {wftm} - Required for liquidity routing when doing swaps.
     * {geist} - Base token on this strategy that is staked at Geist Finance.
     * {rewardBaseTokens} - List of base tokens (NOT gTokens) in which Geist pays rewards, for allowance and swap path purposes.
     */
    address public constant wftm = address(0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83);
    address public constant geist = address(0xd8321AA83Fb0a4ECd6348D4577431310A6E0814d);
    address[] public rewardBaseTokens;

    /**
     * @dev Third Party Contracts:
     * {uniRouter} - the uniRouter for target DEX
     * {geistStaking} - Geist's staking contract
     * {geistAddressesProvider} - Directory to get addresses of latest Geist lending-related contracts
     */
    address public constant uniRouter = address(0xF491e7B69E4244ad4002BC14e878a34207E38c29);
    address public constant geistStaking = address(0x49c93a95dbcc9A6A4D8f77E59c038ce5020e82f8);
    address public constant geistAddressesProvider = address(0x6c793c628Fe2b480c5e6FB7957dDa4b9291F9c9b);

    /**
     * @dev Reaper Contracts:
     * {treasury} - Address of the Reaper treasury
     * {vault} - Address of the vault that controls the strategy's funds.
     */
    address public treasury;
    address public immutable vault;

    /**
    * @dev Distribution of fees earned. This allocations relative to the % implemented on
    * Current implementation separates 5% for fees. Can be changed through the constructor
    * Inputs in constructor should be ratios between the Fee and Max Fee, divisble into percents by 10000
    *
    * {callFee} - Percent of the totalFee reserved for the harvester (1000 = 10% of total fee: 0.5% by default)
    * {treasuryFee} - Percent of the totalFee taken by maintainers of the software (9000 = 90% of total fee: 4.5% by default)
    * {securityFee} - Fee taxed when a user withdraws funds. Taken to prevent flash deposit/harvest attacks.
    * These funds are redistributed to stakers in the pool.
    *
    * {totalFee} - divided by 10,000 to determine the % fee. Set to 5% by default and
    * lowered as necessary to provide users with the most competitive APY.
    *
    * {MAX_FEE} - Maximum fee allowed by the strategy. Hard-capped at 5%.
    * {PERCENT_DIVISOR} - Constant used to safely calculate the correct percentages.
    */

    uint public callFee = 1000;
    uint public treasuryFee = 9000;
    uint public securityFee = 10;
    uint public totalFee = 500;
    uint constant public MAX_FEE = 500;
    uint constant  public PERCENT_DIVISOR = 10000;

    /**
     * @dev Paths use to swap base reward tokens (NOT gTokens) for Geist.
     */
    mapping(address => address[]) public pathForBaseRewardToken;

    /**
     * {StratHarvest} Event that is fired each time someone harvests the strat.
     * {TotalFeeUpdated} Event that is fired each time the total fee is updated.
     * {CallFeeUpdated} Event that is fired each time the call fee is updated.
     * {NewRewardTokenAdded} Event that is fired each time a new Geist reward token is added.
     */
    event StratHarvest(address indexed harvester);
    event TotalFeeUpdated(uint newFee);
    event CallFeeUpdated(uint newCallFee, uint newTreasuryFee);
    event NewRewardTokenAdded(address token);

    /**
     * @dev Initializes the strategy. Sets parameters, saves routes, and gives allowances.
     * @notice see documentation for each variable above its respective declaration.
     */
    constructor (
      address _vault,
      address _treasury,
      address[] memory _rewardTokens
    ) {
        vault = _vault;
        treasury = _treasury;

        for (uint256 i = 0; i < _rewardTokens.length; i++) {
            address token = _rewardTokens[i];
            rewardBaseTokens.push(token);

            if (token == wftm) {
                pathForBaseRewardToken[token] = [token, geist];
            } else {
                pathForBaseRewardToken[token] = [token, wftm, geist];
            }
        }

        giveAllowances();
    }

    /**
     * @dev Function that puts the funds to work.
     * It gets called whenever someone deposits in the strategy's vault contract.
     * It deposits {geist} in the Geist Staking contract to farm all the {rewardBaseTokens}
     */
    function deposit() public whenNotPaused {
        uint256 geistBal = IERC20(geist).balanceOf(address(this));

        if (geistBal > 0) {
            IGeistStaking(geistStaking).stake(geistBal, false); // MUST pass "false" so tokens don't get locked
        }
    }

    /**
     * @dev Withdraws funds and sends them back to the vault.
     * It withdraws {geist} from the Geist Staking contract.
     * The available {geist} minus fees is returned to the vault.
     */
    function withdraw(uint256 _amount) external {
        require(msg.sender == vault, "!vault");

        uint256 geistBal = IERC20(geist).balanceOf(address(this));

        if (geistBal < _amount) {
            IGeistStaking(geistStaking).withdraw(_amount.sub(geistBal));
            geistBal = IERC20(geist).balanceOf(address(this));
        }

        if (geistBal > _amount) {
            geistBal = _amount;
        }
        uint256 withdrawFee = geistBal.mul(securityFee).div(PERCENT_DIVISOR);
        IERC20(geist).safeTransfer(vault, geistBal.sub(withdrawFee));
    }

    /**
     * @dev Core function of the strat, in charge of collecting and re-investing rewards.
     * 1. It claims rewards from the Geist Staking contract in terms of gTokens (gWFTM, gDAI, gETH etc.)
     * 2. For each earned reward gToken:
     *    - withdraw the corresponding underlying base token (WFTM, DAI, ETH etc.) from the Geist Lending Pool
     *    - swap base token for Geist tokens.
     * 3. It charges the system fees out of the newly earned Geist tokens.
     * 4. It deposits the remaining Geist tokens back into the staking contract.
     *
     * TODO tess3rac7, swap all reward tokens to FTM first, charge fees, then swap remaining FTM to Geist
     */
    function harvest() external whenNotPaused {
        require(!Address.isContract(msg.sender), "!contract");

        IGeistStaking stakingContract = IGeistStaking(geistStaking);
        ILendingPool lendingPool = ILendingPool(ILendingPoolAddressesProvider(geistAddressesProvider).getLendingPool());
        uint256 startingGeistBalance = balanceOfGeist();

        // 1. claims rewards from the Geist Staking contract
        IGeistStaking.RewardData[] memory rewardDataArray = stakingContract.claimableRewards(address(this));
        stakingContract.getReward();

        // 2. For each earned reward gToken:
        for (uint256 i = 0; i < rewardDataArray.length; i++) {
            // - withdraw the underlying base token from the Geist Lending Pool
            address baseToken = IAToken(rewardDataArray[i].token).UNDERLYING_ASSET_ADDRESS();
            uint256 amount = lendingPool.withdraw(baseToken, type(uint256).max, msg.sender);

            // - swap base token for Geist tokens.
            IUniswapRouterETH(uniRouter).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                amount, 0, pathForBaseRewardToken[baseToken], address(this), block.timestamp.add(600)
            );
        }

        chargeFees(balanceOfGeist() - startingGeistBalance);
        deposit();

        emit StratHarvest(msg.sender);
    }

    /**
     * @dev Takes out fees from the rewards. Set by constructor
     * callFeeToUser is set as a percentage of the fee,
     * as is treasuryFeeToVault
     */
    function chargeFees(uint256 _profit) internal {
        // TODO tess3rac7 are we happy accepting fee in Geist?
        uint256 callFeeToUser = _profit.mul(callFee).div(PERCENT_DIVISOR);
        IERC20(geist).safeTransfer(msg.sender, callFeeToUser);

        uint256 treasuryFeeToVault = _profit.mul(treasuryFee).div(PERCENT_DIVISOR);
        IERC20(geist).safeTransfer(treasury, treasuryFeeToVault);
    }

    /**
     * @dev Function to calculate the total underlying {geist} held by the strat.
     * It takes into account both the funds in hand, as the funds allocated in the Geist Staking contract.
     */
    function balanceOf() public view returns (uint256) {
        return balanceOfGeist().add(balanceOfPool());
    }

    /**
     * @dev It calculates how much {geist} the contract holds.
     */
    function balanceOfGeist() public view returns (uint256) {
        return IERC20(geist).balanceOf(address(this));
    }

    /**
     * @dev It calculates how much {geist} the strategy has allocated in the Geist staking contract
     */
    function balanceOfPool() public view returns (uint256) {
        return IGeistStaking(geistStaking).totalBalance(address(this));
    }

    /**
     * @dev Function that has to be called as part of strat migration. It sends all the available funds back to the
     * vault, ready to be migrated to the new strat.
     */
    function retireStrat() external {
        require(msg.sender == vault, "!vault");

        IGeistStaking(geistStaking).exit();

        // TODO tess3rac7 probably also swap all earned rewards for Geist here??

        uint256 geistBal = IERC20(geist).balanceOf(address(this));
        IERC20(geist).transfer(vault, geistBal);
    }

    /**
     * @dev Pauses deposits. Gets all withdrawable funds from the Geist Staking contract, leaving rewards behind
     */
    function panic() public onlyOwner {
        pause();
        (uint256 withdrawableBalance, ) = IGeistStaking(geistStaking).withdrawableBalance(address(this));
        IGeistStaking(geistStaking).withdraw(withdrawableBalance);
    }

    /**
     * @dev Pauses the strat.
     */
    function pause() public onlyOwner {
      _pause();
      removeAllowances();
    }

    /**
     * @dev Unpauses the strat.
     */
    function unpause() external onlyOwner {
        _unpause();

        giveAllowances();

        deposit();
    }

    /**
     * @dev Add a new reward token if Geist ever adds a new market that pays rewards to stakers.
     * Should only be called when the strategy is not paused as we will also be giving allowances for
     * this new token within this function.
     */
    function addRewardToken(address _token) external onlyOwner whenNotPaused returns (bool) {
        rewardBaseTokens.push(_token);

        if (_token == wftm) {
            pathForBaseRewardToken[_token] = [_token, geist];
        } else {
            pathForBaseRewardToken[_token] = [_token, wftm, geist];
        }

        IERC20(_token).safeApprove(uniRouter, 0);
        IERC20(_token).safeApprove(uniRouter, type(uint256).max);

        emit NewRewardTokenAdded(_token);
        return true;
    }

    function giveAllowances() internal {
        IERC20(geist).safeApprove(geistStaking, type(uint256).max);

        for (uint256 i = 0; i < rewardBaseTokens.length; i++) {
            IERC20(rewardBaseTokens[i]).safeApprove(uniRouter, 0);
            IERC20(rewardBaseTokens[i]).safeApprove(uniRouter, type(uint256).max);
        }
    }

    function removeAllowances() internal {
        IERC20(geist).safeApprove(geistStaking, 0);

        for (uint256 i = 0; i < rewardBaseTokens.length; i++) {
            IERC20(rewardBaseTokens[i]).safeApprove(uniRouter, 0);
        }
    }

    /**
     * @dev updates the total fee, capped at 5%
     */
    function updateTotalFee(uint _totalFee) external onlyOwner returns (bool) {
      require(_totalFee <= MAX_FEE, "Fee Too High");
      totalFee = _totalFee;
      emit TotalFeeUpdated(totalFee);
      return true;
    }

    /**
     * @dev updates the call fee and adjusts the treasury fee to cover the difference
     */
    function updateCallFee(uint _callFee) external onlyOwner returns (bool) {
      callFee = _callFee;
      treasuryFee = PERCENT_DIVISOR.sub(callFee);
      emit CallFeeUpdated(callFee, treasuryFee);
      return true;
    }

    function updateTreasury(address newTreasury) external onlyOwner returns (bool) {
      treasury = newTreasury;
      return true;
    }
}
