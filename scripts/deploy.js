const Treasury = "0x0e7c5313E9BB80b654734d9b7aB1FB01468deE3b";
const PaymentRouter = "0x603e60D22af05ff77FDCf05c063f582C40e55aae";
const FeeRemitters = [Treasury, PaymentRouter];

const Tess = "0x1A20D7A31e5B3Bc5f02c8A146EF6f394502a10c4";
const Strategists = [Tess];

const RewardTokens = [
  "0x8D11eC38a3EB5E956B052f67Da8Bdc9bef8Abf3E", // DAI
  "0x74b23882a30290451A17c44f4F05243b6b58C76d", // WETH
  // skip WFTM
  "0x321162Cd933E2Be498Cd2267a90534A804051b11", // WBTC
  "0x049d68029688eAbF473097a2fC38ef61633A3C7A", // fUSDT
  "0x04068DA6C83AFCFA0e13ba15A6696662335D5B75", // USDC
  "0x1E4F97b9f9F913c46F1632781732927B9019C68b", // CRV
  "0x82f0B8B456c1A451378467398982d4834b6829c1", // MIM
  "0xb3654dc3D10Ea7645f8319668E8F54d2574FBdC8", // LINK
];

const GEIST = "0xd8321AA83Fb0a4ECd6348D4577431310A6E0814d";

async function main() {
  const [deployer] = await ethers.getSigners();

  console.log("Deploying contracts with the account:", deployer.address);

  console.log("Account balance:", (await deployer.getBalance()).toString());

  // For some reason doing multiple transactions in here can fail
  // Hence comment/uncomment as necessary to ensure vault/strat aren't deployed twice
  const vaultFactory = await ethers.getContractFactory("ReaperVaultv1_3");
  const vaultcontract = await vaultFactory.attach(
    "0xB259d75fF80e3069bcf6Cb28aa5B2191FCd6a13C"
  );
  //   GEIST,
  //   "Geist Single Sided Staking Crypt",
  //   "rfGEIST",
  //   ethers.BigNumber.from("60"), // approvalDelay 60secs
  //   ethers.BigNumber.from("0"), // depositFee 0
  //   ethers.BigNumber.from("200000000000000000000000") // tvlCap 200k tokens
  // );

  // console.log("Vault Contract address:", vaultcontract.address);

  const stratFactory = await ethers.getContractFactory(
    "ReaperAutoCompoundGeist"
  );
  const stratContract = await stratFactory.attach(
    "0x09513B48033eaA50a192Ecf8d65e2ea5211eabf7"
  );
  //   vaultcontract.address,
  //   FeeRemitters,
  //   Strategists,
  //   RewardTokens
  // );

  // console.log("Strategy Contract address:", stratContract.address);

  await vaultcontract.initialize(stratContract.address);

  console.log("Vault initialized");

  // Remember to manually add strategy to PaymentRouter!
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
