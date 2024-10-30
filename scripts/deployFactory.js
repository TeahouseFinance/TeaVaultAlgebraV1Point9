const { ethers, upgrades } = require("hardhat");

function loadEnvVar(env, errorMsg) {
    if (env == undefined) {
        throw errorMsg;
    }

    return env;
}

function loadEnvVarInt(env, errorMsg) {
    if (env == undefined) {
        throw errorMsg;
    }

    return parseInt(env);
}

const owner = loadEnvVar(process.env.OWNER, "No OWNER");;
const poolFactory = loadEnvVar(process.env.POOL_FACTORY, "No POOL_FACTORY");

async function main() {
    const VaultUtils = await ethers.getContractFactory("VaultUtils");
    const vaultUtils = await VaultUtils.deploy();
    console.log("VaultUtils deployed", vaultUtils.target);

    const TeaVaultAlgebraV1Point9 = await ethers.getContractFactory("TeaVaultAlgebraV1Point9", {
        libraries: { VaultUtils: vaultUtils.target },
    });
    const beacon = await upgrades.deployBeacon(TeaVaultAlgebraV1Point9, {
            unsafeAllowLinkedLibraries: true,
            unsafeAllow: ["delegatecall"],
    });
    console.log("beacon deployed", beacon.target);

    const TeaVaultAlgebraV1Point9Factory = await ethers.getContractFactory("TeaVaultAlgebraV1Point9Factory");
    const teaVaultAlgebraV1Point9Factory = await upgrades.deployProxy(
        TeaVaultAlgebraV1Point9Factory,
        [
            owner,
            beacon.target,
            poolFactory
        ]
    );

    console.log("TeaVaultAlgebraV1Point9Factory deployed", teaVaultAlgebraV1Point9Factory.target);
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});