// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./ReaperBaseStrategy.sol";
import "./interfaces/IAToken.sol";
import "./interfaces/IGeistStaking.sol";
import "./interfaces/ILendingPool.sol";
import "./interfaces/ILendingPoolAddressesProvider.sol";
import "./interfaces/IUniswapV2Router02.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
contract ReaperAutoCompoundGeist is ReaperBaseStrategy {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    /**
     * @dev Tokens Used:
     * {wftm} - Required for liquidity routing when doing swaps.
     * {geist} - Base token on this strategy that is staked at Geist Finance.
     * {rewardBaseTokens} - List of base tokens (NOT gTokens) other than wFTM in which Geist pays rewards,
     *                      for allowance and swap path purposes.
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
     * @dev Paths used to swap tokens:
     * {pathForBaseRewardToken} - to swap base reward tokens (NOT gTokens) for {wftm}.
     * {wftmToGeistPath} - to swap {wftm} to {geist}
     */
    mapping(address => address[]) public pathForBaseRewardToken;
    address[] public wftmToGeistPath = [wftm, geist];

    /**
     * {NewRewardTokenAdded} Event that is fired each time a new Geist reward token is added.
     */
    event NewRewardTokenAdded(address token);

    /**
     * @dev Initializes the strategy. Sets parameters, saves routes, and gives allowances.
     * @notice see documentation for each variable above its respective declaration.
     */
    constructor (
      address _vault,
      address _treasury,
      address[] memory _rewardTokens
    ) ReaperBaseStrategy(_vault, _treasury) {
        for (uint256 i = 0; i < _rewardTokens.length; i++) {
            address token = _rewardTokens[i];
            rewardBaseTokens.push(token);
            pathForBaseRewardToken[token] = [token, wftm];
        }

        giveAllowances();
    }

    /**
     * @dev Function that puts the funds to work.
     * It gets called whenever someone deposits in the strategy's vault contract.
     * It deposits {geist} in the Geist Staking contract to farm all the {rewardBaseTokens}
     */
    // TODO tess3rac7 can we make this overridden with the modifier?
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
    // TODO tess3rac7 pull this up, check vault, rest in withdrawInternal
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
     *    - swap base token for wFTM tokens.
     * 3. It charges the system fees out of the newly earned wFTM tokens.
     * 4. It swaps the remaining wFTM into Geist and deposits it back into the staking contract.
     */
    function _harvestCore() override internal {
        claimRewardsAndSwapToWftm();
        chargeFees();
        convertWftmToGeist();
        deposit();
    }

    /**
     * @dev Returns the approx amount of profit from harvesting.
     *      Profit is denominated in WFTM, and takes fees into account.
     */
    function estimateHarvest() external view override returns (uint256 profit, uint256 callFeeToUser) {
        IGeistStaking.RewardData[] memory rewardDataArray =  IGeistStaking(geistStaking).claimableRewards(address(this));
        for (uint256 i = 0; i < rewardDataArray.length; i++) {
            // Geist rewards not applicable since we're not locking
            // also skip tokens with 0 reward
            if (rewardDataArray[i].token == geist || rewardDataArray[i].amount == 0) {
                continue;
            }

            // for all other reward gTokens, add wFTM equivalent to profit
            address baseToken = IAToken(rewardDataArray[i].token).UNDERLYING_ASSET_ADDRESS();
            if (baseToken == wftm) {
                profit = profit.add(rewardDataArray[i].amount);
            } else {
                uint[] memory amountOutMins = IUniswapV2Router02(uniRouter).getAmountsOut(
                    rewardDataArray[i].amount,
                    pathForBaseRewardToken[baseToken]
                );
                profit = profit.add(amountOutMins[1]);
            }
        }

        // take out fees from profit
        uint256 wftmFee = profit.mul(totalFee).div(PERCENT_DIVISOR);
        callFeeToUser = wftmFee.mul(callFee).div(PERCENT_DIVISOR);
        profit = profit.sub(wftmFee);
    }

    /**
     * @dev Claim rewards from the Geist staking contract (gWFTM, gDAI etc.),
     *      withdraws underlying assets (WFTM, DAI, etc.) from the lending pool,
     *      swaps all of them to Wftm
     */
    function claimRewardsAndSwapToWftm() internal {
        IGeistStaking stakingContract = IGeistStaking(geistStaking);
        ILendingPool lendingPool = ILendingPool(ILendingPoolAddressesProvider(geistAddressesProvider).getLendingPool());

        // 1. claims rewards from the Geist Staking contract
        IGeistStaking.RewardData[] memory rewardDataArray = stakingContract.claimableRewards(address(this));
        stakingContract.getReward();

        // 2. For each earned reward gToken:
        for (uint256 i = 0; i < rewardDataArray.length; i++) {
            // (skip Geist as we won't have any locking rewards but it's returned anyway)
            // (also skip if this token doesn't have any rewards)
            if (rewardDataArray[i].token == geist || rewardDataArray[i].amount == 0) {
                continue;
            }

            // - withdraw the underlying base token from the Geist Lending Pool
            address baseToken = IAToken(rewardDataArray[i].token).UNDERLYING_ASSET_ADDRESS();
            uint256 amount = lendingPool.withdraw(baseToken, type(uint256).max, address(this));

            // - swap base token for wFTM (if it isn't already wFTM)
            if (baseToken != wftm) {
                IUniswapV2Router02(uniRouter).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    amount, 0, pathForBaseRewardToken[baseToken], address(this), block.timestamp.add(600)
                );
            }
        }
    }

    /**
     * @dev Takes out fees from the rewards. Set by constructor
     * callFeeToUser is set as a percentage of the fee,
     * as is treasuryFeeToVault
     */
    function chargeFees() internal {
        uint256 wftmFee = IERC20(wftm).balanceOf(address(this)).mul(totalFee).div(PERCENT_DIVISOR);

        if (wftmFee != 0) {
            uint256 callFeeToUser = wftmFee.mul(callFee).div(PERCENT_DIVISOR);
            IERC20(wftm).safeTransfer(msg.sender, callFeeToUser);

            uint256 treasuryFeeToVault = wftmFee.mul(treasuryFee).div(PERCENT_DIVISOR);
            IERC20(wftm).safeTransfer(treasury, treasuryFeeToVault);
        }
    }

    /**
     * @dev Converts all of this contract's {wftm} balance into {geist}.
     *      Typically called during harvesting to transform assets back into
     *      {geist} for staking.
     */
    function convertWftmToGeist() internal {
        uint256 wftmBal = IERC20(wftm).balanceOf(address(this));
        if (wftmBal != 0) {
            IUniswapV2Router02(uniRouter).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                wftmBal, 0, wftmToGeistPath, address(this), block.timestamp.add(600)
            );
        }
    }

    /**
     * @dev Function to calculate the total underlying {geist} held by the strat.
     * It takes into account both the funds in hand, as the funds allocated in the Geist Staking contract.
     */
    function balanceOf() public view override returns (uint256) {
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
    // TODO tess3rac7 pull this up, check vault, rest in retireStratInternal
    function retireStrat() external {
        require(msg.sender == vault, "!vault");

        claimRewardsAndSwapToWftm();
        convertWftmToGeist();
        IGeistStaking(geistStaking).withdraw(balanceOfPool());

        uint256 geistBal = IERC20(geist).balanceOf(address(this));
        IERC20(geist).transfer(vault, geistBal);
    }

    /**
     * @dev Pauses deposits. Gets all withdrawable funds from the Geist Staking contract, leaving rewards behind
     */
    // TODO tess3rac7 overridden
    function panic() external onlyOwner {
        pause();
        (uint256 withdrawableBalance, ) = IGeistStaking(geistStaking).withdrawableBalance(address(this));
        IGeistStaking(geistStaking).withdraw(withdrawableBalance);
    }

    /**
     * @dev Pauses the strat.
     */
    // TODO tess3rac7 overridden
    function pause() public onlyOwner {
      _pause();
      removeAllowances();
    }

    /**
     * @dev Unpauses the strat.
     */
    // TODO tess3rac7 overridden
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
    function addRewardToken(address _token, address[] calldata _path) external onlyOwner whenNotPaused returns (bool) {
        rewardBaseTokens.push(_token);
        pathForBaseRewardToken[_token] = _path;

        IERC20(_token).safeApprove(uniRouter, 0);
        IERC20(_token).safeApprove(uniRouter, type(uint256).max);

        emit NewRewardTokenAdded(_token);
        return true;
    }

    function giveAllowances() internal {
        IERC20(geist).safeApprove(geistStaking, type(uint256).max);
        IERC20(wftm).safeApprove(uniRouter, type(uint256).max);

        for (uint256 i = 0; i < rewardBaseTokens.length; i++) {
            IERC20(rewardBaseTokens[i]).safeApprove(uniRouter, 0);
            IERC20(rewardBaseTokens[i]).safeApprove(uniRouter, type(uint256).max);
        }
    }

    function removeAllowances() internal {
        IERC20(geist).safeApprove(geistStaking, 0);
        IERC20(wftm).safeApprove(uniRouter, 0);

        for (uint256 i = 0; i < rewardBaseTokens.length; i++) {
            IERC20(rewardBaseTokens[i]).safeApprove(uniRouter, 0);
        }
    }
}
