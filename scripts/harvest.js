const STRATEGY_ADDR = "0x09513B48033eaA50a192Ecf8d65e2ea5211eabf7";
const DAY = ethers.BigNumber.from(24 * 60 * 60);

async function main() {
  const [harvester] = await ethers.getSigners();
  const stratFactory = await ethers.getContractFactory(
    "ReaperAutoCompoundGeist"
  );
  const stratContract = await stratFactory.attach(STRATEGY_ADDR);

  // does callFee beat gas required?
  const gasPrice = await harvester.getGasPrice();
  const harvestEstimatedGas = await stratContract.estimateGas.harvest();
  const harvestEstimatedFTM = harvestEstimatedGas.mul(gasPrice);
  const estimatedCallFee = (await stratContract.estimateHarvest())
    .callFeeToUser;

  if (estimatedCallFee.gte(harvestEstimatedFTM)) {
    await stratContract.harvest();
    return;
  }

  // if not, has it been more than a full day since last harvest?
  const lastHarvestTimestamp = await stratContract.lastHarvestTimestamp();
  const now = ethers.BigNumber.from(Math.floor(Date.now() / 1000));
  const timeSinceLastHarvest = now.sub(lastHarvestTimestamp);

  if (timeSinceLastHarvest.gte(DAY)) {
    await stratContract.harvest();
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
