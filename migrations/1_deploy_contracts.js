// var DWORM = artifacts.require("DWORM");
var Staking = artifacts.require("DwormStakingV1");

module.exports = async function (deployer) {
  await deployer.deploy(Staking);
};
