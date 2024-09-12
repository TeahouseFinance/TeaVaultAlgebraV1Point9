const helpers = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { anyValue } = require("@nomicfoundation/hardhat-chai-matchers/withArgs");
const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

const UINT256_MAX = '0x' + 'f'.repeat(64);
const UINT64_MAX = '0x' + 'f'.repeat(16);

const UniswapV3SwapRouterABI = [
    "function WETH9() external view returns (address)",
    "function exactInputSingle((address,address,uint24,address,uint256,uint256,uint256,uint160)) external payable returns (uint256)",
    "function multicall(bytes[] calldata data) external payable returns (bytes[] memory results)",
    "function unwrapWETH9(uint256 amountMinimum, address recipient) external payable",
    "function refundETH() external payable"
];

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


// setup ambient parameters
const testRpc = loadEnvVar(process.env.TEST_RPC, "No TEST_RPC");
const testBlock = loadEnvVarInt(process.env.TEST_BLOCK, "No TEST_BLOCK");
const testPoolFactory = loadEnvVar(process.env.TEST_POOL_FACTORY, "No TEST_POOL_FACTORY");
const testToken0 = loadEnvVar(process.env.TEST_TOKEN0, "No TEST_TOKEN0");
const testToken1 = loadEnvVar(process.env.TEST_TOKEN1, "No TEST_TOKEN1");
const testToken0Whale = loadEnvVar(process.env.TEST_TOKEN0_WHALE, "No TEST_TOKEN0_WHALE");
const testToken1Whale = loadEnvVar(process.env.TEST_TOKEN1_WHALE, "No TEST_TOKEN1_WHALE");
const testRouter = loadEnvVar(process.env.TEST_UNISWAP_ROUTER, "No TEST_UNISWAP_ROUTER");

describe("TeaVaultAlgebraV1Point9", function () {
    async function deployTeaVaultFixture() {
        // fork a testing environment
        await helpers.reset(testRpc, testBlock);

        // Contracts are deployed using the first signer/account by default
        const [ owner, manager, treasury, user ] = await ethers.getSigners();

        // get ERC20 tokens
        const MockToken = await ethers.getContractFactory("MockToken");
        const token0 = MockToken.attach(testToken0);
        const token1 = MockToken.attach(testToken1);

        // get tokens from whale
        await helpers.impersonateAccount(testToken0Whale);
        const token0Whale = await ethers.getSigner(testToken0Whale);
        await helpers.setBalance(token0Whale.address, ethers.parseEther("100"));  // assign some eth to the whale in case it's a contract and not accepting eth
        await token0.connect(token0Whale).transfer(user, ethers.parseUnits("100", await token0.decimals()));

        await helpers.impersonateAccount(testToken1Whale);
        const token1Whale = await ethers.getSigner(testToken1Whale);
        await helpers.setBalance(token1Whale.address, ethers.parseEther("100"));  // assign some eth to the whale in case it's a contract and not accepting eth
        await token1.connect(token1Whale).transfer(user, ethers.parseUnits("100", await token1.decimals()));

        // deploy vault
        const VaultUtils = await ethers.getContractFactory("VaultUtils");
        const vaultUtils = await VaultUtils.deploy();

        const TeaVaultAlgebra = await ethers.getContractFactory("TeaVaultAlgebraV1Point9", {
            libraries: {
                VaultUtils: vaultUtils.target,
            },
        });
        const algebraBeacon = await upgrades.deployBeacon(TeaVaultAlgebra,
            {
                unsafeAllowLinkedLibraries: true, 
                unsafeAllow: [ 'delegatecall' ],
            },
        );

        const TeaVaultAlgebraFactory = await ethers.getContractFactory("TeaVaultAlgebraV1Point9Factory");
        const teaVaultAlgebraFactory = await upgrades.deployProxy(
            TeaVaultAlgebraFactory,
            [
                owner.address,
                algebraBeacon.target,
                testPoolFactory,
            ]
        );

        // find decimal offset to make TeaVault decimals >= 18
        const token0Decimals = await token0.decimals();
        let decimalOffset;
        if (token0Decimals < 18n) {
            decimalOffset = 18n - token0Decimals;
        }
        else {
            decimalOffset = 0n;
        }

        // create pool
        const tx = await teaVaultAlgebraFactory.createVault(
            owner.address,
            "Test Vault",
            "TVAULT",
            decimalOffset,
            testToken0,
            testToken1,
            manager.address,
            999999,
            {
                treasury: treasury.address,
                entryFee: 0,
                exitFee: 0,
                performanceFee: 0,
                managementFee: 0,
            },
        );

        events = await teaVaultAlgebraFactory.queryFilter("VaultDeployed", tx.blockNumber, tx.blockNumber);
        const vault = TeaVaultAlgebra.attach(events[0].args[0]);

        return { owner, manager, treasury, user, vault, token0, token1 };
    }

    describe("Deployment", function() {
        it("Should set the correct tokens", async function () {
            const { vault, token0, token1 } = await helpers.loadFixture(deployTeaVaultFixture);

            expect(await vault.assetToken0()).to.equal(token0.target);
            expect(await vault.assetToken1()).to.equal(token1.target);

            const poolInfo = await vault.getPoolInfo();
            expect(poolInfo[0]).to.equal(token0.target);
            expect(poolInfo[1]).to.equal(token1.target);
        });

        it("Should set the correct decimals", async function () {
            const { vault } = await helpers.loadFixture(deployTeaVaultFixture);

            expect(await vault.decimals()).to.equal(18);
        });
    });

    describe("Owner functions", function() {
        it("Should be able to set fees from owner", async function() {
            const { owner, vault } = await helpers.loadFixture(deployTeaVaultFixture);

            const feeConfig = {
                treasury: owner.address,
                entryFee: 1000,
                exitFee: 2000,
                performanceFee: 100000,
                managementFee: 10000,
            };

            await vault.setFeeConfig(feeConfig);
            const fees = await vault.feeConfig();

            expect(feeConfig.treasury).to.equal(fees.treasury);
            expect(feeConfig.entryFee).to.equal(fees.entryFee);
            expect(feeConfig.exitFee).to.equal(fees.exitFee);
            expect(feeConfig.performanceFee).to.equal(fees.performanceFee);
            expect(feeConfig.managementFee).to.equal(fees.managementFee);
        });

        it("Should not be able to set incorrect fees", async function() {
            const { owner, vault } = await helpers.loadFixture(deployTeaVaultFixture);

            const feeConfig1 = {
                treasury: owner.address,
                entryFee: 500001,
                exitFee: 500000,
                performanceFee: 100000,
                managementFee: 10000,
            };

            await expect(vault.setFeeConfig(feeConfig1))
            .to.be.revertedWithCustomError(vault, "InvalidFeePercentage");

            const feeConfig2 = {
                treasury: owner.address,
                entryFee: 1000,
                exitFee: 2000,
                performanceFee: 1000001,
                managementFee: 10000,
            };

            await expect(vault.setFeeConfig(feeConfig2))
            .to.be.revertedWithCustomError(vault, "InvalidFeePercentage");

            const feeConfig3 = {
                treasury: owner.address,
                entryFee: 1000,
                exitFee: 2000,
                performanceFee: 100000,
                managementFee: 1000001,
            };

            await expect(vault.setFeeConfig(feeConfig3))
            .to.be.revertedWithCustomError(vault, "InvalidFeePercentage");
        });

        it("Should not be able to set fees from non-owner", async function() {
            const { manager, vault } = await helpers.loadFixture(deployTeaVaultFixture);

            const feeConfig = {
                treasury: manager.address,
                entryFee: 1000,
                exitFee: 2000,
                performanceFee: 100000,
                managementFee: 10000,
            }

            await expect(vault.connect(manager).setFeeConfig(feeConfig))
            .to.be.revertedWithCustomError(vault, "OwnableUnauthorizedAccount");
        });

        it("Should be able to assign manager from owner", async function() {
            const { manager, vault } = await helpers.loadFixture(deployTeaVaultFixture);

            await vault.assignManager(manager.address);
            expect(await vault.manager()).to.equal(manager.address);
        });

        it("Should not be able to assign manager from non-owner", async function() {
            const { manager, user, vault } = await helpers.loadFixture(deployTeaVaultFixture);

            await expect(vault.connect(manager).assignManager(user.address))
            .to.be.revertedWithCustomError(vault, "OwnableUnauthorizedAccount");
            expect(await vault.manager()).to.equal(manager.address);
        });
    });

    describe("User functions", function() {        
        it("Should be able to deposit and withdraw from user", async function() {
            const { treasury, user, vault, token0 } = await helpers.loadFixture(deployTeaVaultFixture);

            // set fees
            const feeConfig = {
                treasury: treasury.address,
                entryFee: 1000n,
                exitFee: 2000n,
                performanceFee: 100000n,
                managementFee: 10000n,
            }

            await vault.setFeeConfig(feeConfig);

            const feeMultiplier = await vault.FEE_MULTIPLIER();

            // deposit
            const token0Decimals = await token0.decimals();
            const vaultDecimals = await vault.decimals();
            const shares = ethers.parseUnits("1", vaultDecimals);
            const token0Amount = ethers.parseUnits("1", token0Decimals);
            const token0EntryFee = token0Amount * feeConfig.entryFee / feeMultiplier;
            const token0AmountWithFee = token0Amount + token0EntryFee;

            let token0Before = await token0.balanceOf(user);
            let treasureBefore = await token0.balanceOf(treasury);
            
            // deposit native token
            await token0.connect(user).approve(vault, token0AmountWithFee);
            expect(await vault.connect(user).deposit(shares, token0AmountWithFee, 0n))
            .to.changeTokenBalance(vault, user, shares);
            let token0After = await token0.balanceOf(user);
            expect(token0Before - token0After).to.equal(token0AmountWithFee);

            expect(await token0.balanceOf(vault)).to.equal(token0Amount);    // vault received amount0
            let treasureAfter = await token0.balanceOf(treasury);
            expect(treasureAfter - treasureBefore).to.equal(token0EntryFee);        // treasury received entry fee

            const depositTime = await vault.lastCollectManagementFee();

            // withdraw
            token0Before = await token0.balanceOf(user);
            expect( await vault.connect(user).withdraw(shares, 0, 0))
            .to.changeTokenBalance(vault, user, -shares);
            token0After = await token0.balanceOf(user);

            const withdrawTime = await vault.lastCollectManagementFee();
            const managementFeeTimeDiff = feeConfig.managementFee * (withdrawTime - depositTime);
            const secondsInAYear = await vault.SECONDS_IN_A_YEAR();
            const denominator = feeMultiplier * secondsInAYear - managementFeeTimeDiff;
            const managementFee = (shares * managementFeeTimeDiff + denominator - 1n) / denominator;    // shares in management fee

            const exitFeeShares = shares * feeConfig.exitFee / feeMultiplier;
            const totalSupply = await vault.totalSupply();
            expect(totalSupply).to.equal(managementFee + exitFeeShares);    // remaining share tokens

            expectedAmount0 = token0Amount * (shares - exitFeeShares) / (shares + managementFee);
            expect(token0After - token0Before).to.be.closeTo(expectedAmount0, 100); // user received expectedAmount0 of token0
            expect(await vault.balanceOf(treasury.address)).to.equal(exitFeeShares + managementFee); // treasury received exitFeeShares and managementFee of share
        });

        it("Should not be able to deposit and withdraw incorrect amounts", async function() {
            const { user, treasury, vault, token0 } = await helpers.loadFixture(deployTeaVaultFixture);

            // set fees
            const feeConfig = {
                treasury: treasury.address,
                entryFee: 1000n,
                exitFee: 2000n,
                performanceFee: 100000n,
                managementFee: 10000n,
            }

            await vault.setFeeConfig(feeConfig);

            const feeMultiplier = await vault.FEE_MULTIPLIER();

            // deposit without enough value
            const token0Decimals = await token0.decimals();
            const vaultDecimals = await vault.decimals();
            const shares = ethers.parseUnits("1", vaultDecimals);
            const token0Amount = ethers.parseUnits("1", token0Decimals);
            const token0EntryFee = token0Amount * feeConfig.entryFee / feeMultiplier;
            const token0AmountWithFee = token0Amount + token0EntryFee;
            
            await token0.connect(user).approve(vault, token0Amount);
            await expect(vault.connect(user).deposit(shares, token0AmountWithFee, 0))
            .to.be.reverted;    // likely to be reverted with ERC20 token's insufficient allowance

            await token0.connect(user).approve(vault, token0Amount);
            await expect(vault.connect(user).deposit(shares, token0Amount, 0))
            .to.be.reverted;    // likely to be reverted with ERC20 token's insufficient allowance

            await token0.connect(user).approve(vault, 0n);
            await token0.connect(user).approve(vault, token0AmountWithFee);
            await vault.connect(user).deposit(shares, token0AmountWithFee, 0);

            // withdraw more than owned shares
            await expect(vault.connect(user).withdraw(shares * 2n, 0, 0))
            .to.be.revertedWithCustomError(vault, "ERC20InsufficientBalance");
        });

        it("Should revert with slippage checks when withdrawing", async function() {
            const { user, vault, token0 } = await helpers.loadFixture(deployTeaVaultFixture);

            const token0Decimals = await token0.decimals();
            const vaultDecimals = await vault.decimals();
            const shares = ethers.parseUnits("1", vaultDecimals);
            const token0Amount = ethers.parseUnits("1", token0Decimals);

            await token0.connect(user).approve(vault, token0Amount);
            await vault.connect(user).deposit(shares, token0Amount, 0);

            // withdraw with slippage check
            await expect(vault.connect(user).withdraw(shares, token0Amount + 100n, 0n))
            .to.be.revertedWithCustomError(vault, "InvalidPriceSlippage");
        });
    });

    describe("Manager functions", function() {
        it("Should be able to swap in pool", async function() {
            const { user, manager, vault, token0, token1 } = await helpers.loadFixture(deployTeaVaultFixture);

            // deposit
            const token0Decimals = await token0.decimals();
            const vaultDecimals = await vault.decimals();
            const shares = ethers.parseUnits("1", vaultDecimals);
            const token0Amount = ethers.parseUnits("1", token0Decimals);
            await token0.connect(user).approve(vault, token0Amount);
            await vault.connect(user).deposit(shares, token0Amount, 0n);

            // manager swap, using UniswapV3
            const swapAmount = token0Amount / 2n;
            await vault.connect(manager).inPoolSwap(true, swapAmount, 0);

            const amount0AfterSwap = await token0.balanceOf(vault);
            expect(amount0AfterSwap).to.gte(token0Amount - swapAmount); // should use swapAmount or less
        });

        it("Should not be able to swap in pool with wrong slippage", async function() {
            const { user, manager, vault, token0, token1 } = await helpers.loadFixture(deployTeaVaultFixture);

            // deposit
            const token0Decimals = await token0.decimals();
            const vaultDecimals = await vault.decimals();
            const shares = ethers.parseUnits("1", vaultDecimals);
            const token0Amount = ethers.parseUnits("1", token0Decimals);
            await token0.connect(user).approve(vault, token0Amount);
            await vault.connect(user).deposit(shares, token0Amount, 0n);

            // manager swap, using UniswapV3
            const swapAmount = token0Amount / 2n;
            const outAmounts = await vault.connect(manager).inPoolSwap.staticCall(true, swapAmount, 0);
            await expect(vault.connect(manager).inPoolSwap(true, swapAmount, outAmounts[1] + 1n))
            .to.be.reverted; // could be reverted in pool or in vault
        });

        it("Should not be able to swap in pool from non-manager", async function() {
            const { user, vault, token0, token1 } = await helpers.loadFixture(deployTeaVaultFixture);

            // deposit
            const token0Decimals = await token0.decimals();
            const vaultDecimals = await vault.decimals();
            const shares = ethers.parseUnits("1", vaultDecimals);
            const token0Amount = ethers.parseUnits("1", token0Decimals);
            await token0.connect(user).approve(vault, token0Amount);
            await vault.connect(user).deposit(shares, token0Amount, 0n);

            // manager swap, using UniswapV3
            const swapAmount = token0Amount / 2n;
            await expect(vault.connect(user).inPoolSwap(true, swapAmount, 0))
            .to.be.revertedWithCustomError(vault, "CallerIsNotManager");
        });

        it("Should be able to swap using 3rd party pool", async function() {
            const { user, manager, vault, token0, token1 } = await helpers.loadFixture(deployTeaVaultFixture);

            // deposit
            const token0Decimals = await token0.decimals();
            const vaultDecimals = await vault.decimals();
            const shares = ethers.parseUnits("1", vaultDecimals);
            const token0Amount = ethers.parseUnits("1", token0Decimals);
            await token0.connect(user).approve(vault, token0Amount);
            await vault.connect(user).deposit(shares, token0Amount, 0n);

            // manager swap, using UniswapV3
            const v3Router = new ethers.Contract(testRouter, UniswapV3SwapRouterABI, ethers.provider);
            const swapAmount = token0Amount / 2n;
            const swapRelayer = await vault.swapRelayer();
            const swapParams = [
                token0.target,
                token1.target,
                500,
                swapRelayer,
                UINT64_MAX,
                swapAmount,
                0n,
                0n
            ];
            await token0.connect(user).approve(v3Router, swapAmount);
            const outAmount = await v3Router.connect(user).exactInputSingle.staticCall(swapParams);
            const uniswapV3SwapData = v3Router.interface.encodeFunctionData("exactInputSingle", [ swapParams ]);
            await vault.connect(manager).executeSwap(true, swapAmount, outAmount, v3Router.target, uniswapV3SwapData);

            const amount0AfterSwap = await token0.balanceOf(vault);
            const amount1AfterSwap = await token1.balanceOf(vault);
            expect(amount0AfterSwap).to.gte(token0Amount - swapAmount); // should use swapAmount or less
            expect(amount1AfterSwap).to.gte(outAmount); // should receive outAmount or more
        });

        it("Should not be able to swap using 3rd party pool with wrong slippage", async function() {
            const { user, manager, vault, token0, token1 } = await helpers.loadFixture(deployTeaVaultFixture);

            // deposit
            const token0Decimals = await token0.decimals();
            const vaultDecimals = await vault.decimals();
            const shares = ethers.parseUnits("1", vaultDecimals);
            const token0Amount = ethers.parseUnits("1", token0Decimals);
            await token0.connect(user).approve(vault, token0Amount);
            await vault.connect(user).deposit(shares, token0Amount, 0n);

            // manager swap, using UniswapV3
            const v3Router = new ethers.Contract(testRouter, UniswapV3SwapRouterABI, ethers.provider);
            const swapAmount = token0Amount / 2n;
            const swapRelayer = await vault.swapRelayer();
            const swapParams = [
                token0.target,
                token1.target,
                500,
                swapRelayer,
                UINT64_MAX,
                swapAmount,
                0n,
                0n
            ];
            await token0.connect(user).approve(v3Router, swapAmount);
            const outAmount = await v3Router.connect(user).exactInputSingle.staticCall(swapParams);
            const uniswapV3SwapData = v3Router.interface.encodeFunctionData("exactInputSingle", [ swapParams ]);
            await expect(vault.connect(manager).executeSwap(true, swapAmount, outAmount + 1n, v3Router.target, uniswapV3SwapData))
            .to.be.reverted; // could be reverted in pool or in vault
        });

        it("Should not be able to swap using 3rd party pool from non-manager", async function() {
            const { user, vault, token0, token1 } = await helpers.loadFixture(deployTeaVaultFixture);

            // deposit
            const token0Decimals = await token0.decimals();
            const vaultDecimals = await vault.decimals();
            const shares = ethers.parseUnits("1", vaultDecimals);
            const token0Amount = ethers.parseUnits("1", token0Decimals);
            await token0.connect(user).approve(vault, token0Amount);
            await vault.connect(user).deposit(shares, token0Amount, 0n);

            // manager swap, using UniswapV3
            const v3Router = new ethers.Contract(testRouter, UniswapV3SwapRouterABI, ethers.provider);
            const swapAmount = token0Amount / 2n;
            const swapRelayer = await vault.swapRelayer();
            const swapParams = [
                token0.target,
                token1.target,
                500,
                swapRelayer,
                UINT64_MAX,
                swapAmount,
                0n,
                0n
            ];
            await token0.connect(user).approve(v3Router, swapAmount);
            const outAmount = await v3Router.connect(user).exactInputSingle.staticCall(swapParams);
            const uniswapV3SwapData = v3Router.interface.encodeFunctionData("exactInputSingle", [ swapParams ]);
            await expect(vault.connect(user).executeSwap(true, swapAmount, outAmount + 1n, v3Router.target, uniswapV3SwapData))
            .to.be.revertedWithCustomError(vault, "CallerIsNotManager");
        });

        it("Should be able to swap, add liquidity, remove liquidity, and withdraw", async function() {
            const { treasury, user, manager, vault, token0, token1 } = await helpers.loadFixture(deployTeaVaultFixture);

            // set fees
            const feeConfig = {
                treasury: treasury.address,
                entryFee: 1000n,
                exitFee: 2000n,
                performanceFee: 100000n,
                managementFee: 0n,          // leave management fee at zero to make sure the vault can be emptied
            }

            await vault.setFeeConfig(feeConfig);

            const feeMultiplier = await vault.FEE_MULTIPLIER();

            // deposit
            const token0Decimals = await token0.decimals();
            const vaultDecimals = await vault.decimals();
            const shares = ethers.parseUnits("1", vaultDecimals);
            const token0Amount = ethers.parseUnits("1", token0Decimals);
            const token0EntryFee = token0Amount * feeConfig.entryFee / feeMultiplier;
            const token0AmountWithFee = token0Amount + token0EntryFee;

            await token0.connect(user).approve(vault, token0AmountWithFee);
            await vault.connect(user).deposit(shares, token0AmountWithFee, 0n);

            // manager swap, using UniswapV3
            const v3Router = new ethers.Contract(testRouter, UniswapV3SwapRouterABI, ethers.provider);
            const swapAmount = token0Amount / 2n;
            const swapRelayer = await vault.swapRelayer();
            const swapParams = [
                token0.target,
                token1.target,
                500,
                swapRelayer,
                UINT64_MAX,
                swapAmount,
                0n,
                0n
            ];
            await token0.connect(user).approve(v3Router, swapAmount);
            const outAmount = await v3Router.connect(user).exactInputSingle.staticCall(swapParams);
            const uniswapV3SwapData = v3Router.interface.encodeFunctionData("exactInputSingle", [ swapParams ]);
            await vault.connect(manager).executeSwap(true, swapAmount, outAmount, v3Router.target, uniswapV3SwapData);

            const amount0AfterSwap = await token0.balanceOf(vault);
            const amount1AfterSwap = await token1.balanceOf(vault);
            expect(amount0AfterSwap).to.gte(token0Amount - swapAmount); // should use swapAmount or less
            expect(amount1AfterSwap).to.gte(outAmount); // should receive outAmount or more

            // add liquidity
            const poolInfo = await vault.getPoolInfo();
            const currentTick = poolInfo[8];
            const tickSpacing = poolInfo[6];

            // add positions
            const tick0 = ((currentTick - tickSpacing * 30n) / tickSpacing) * tickSpacing;
            const tick1 = ((currentTick - tickSpacing * 10n) / tickSpacing) * tickSpacing;
            const tick2 = ((currentTick + tickSpacing * 10n) / tickSpacing) * tickSpacing;
            const tick3 = ((currentTick + tickSpacing * 30n) / tickSpacing) * tickSpacing;

            // add "center" position
            let liquidity1 = await vault.getLiquidityForAmounts(tick1, tick2, amount0AfterSwap / 3n, amount1AfterSwap / 3n);
            await vault.connect(manager).addLiquidity(tick1, tick2, liquidity1, 0, 0, UINT64_MAX);

            let positionInfo = await vault.positionInfo(0);
            let amounts = await vault.getAmountsForLiquidity(tick1, tick2, liquidity1);
            expect(positionInfo[0]).to.be.closeTo(amounts[0], 1n);
            expect(positionInfo[1]).to.be.closeTo(amounts[1], 1n);
            
            // add "lower" position
            const amount1 = await token1.balanceOf(vault);
            let liquidity0 = await vault.getLiquidityForAmounts(tick0, tick1, 0, amount1);
            await vault.connect(manager).addLiquidity(tick0, tick1, liquidity0, 0, 0, UINT64_MAX);

            positionInfo = await vault.positionInfo(1);
            amounts = await vault.getAmountsForLiquidity(tick0, tick1, liquidity0);
            expect(positionInfo[0]).to.be.closeTo(amounts[0], 1n);
            expect(positionInfo[1]).to.be.closeTo(amounts[1], 1n);

            // add "upper" position
            const amount0 = await token1.balanceOf(vault);
            let liquidity2 = await vault.getLiquidityForAmounts(tick2, tick3, amount0, 0); // slightly lower amount1 to avoid precision problem
            await vault.connect(manager).addLiquidity(tick2, tick3, liquidity2, 0, 0, UINT64_MAX);

            positionInfo = await vault.positionInfo(2);
            amounts = await vault.getAmountsForLiquidity(tick2, tick3, liquidity2);
            expect(positionInfo[0]).to.be.closeTo(amounts[0], 1n);
            expect(positionInfo[1]).to.be.closeTo(amounts[1], 1n);

            // check assets and token values
            let assets = await vault.vaultAllUnderlyingAssets();
            expect(assets[0]).to.be.closeTo(amount0AfterSwap, amount0AfterSwap / 100n);
            expect(assets[1]).to.be.closeTo(amount1AfterSwap, amount1AfterSwap / 100n);

            expect(await vault.estimatedValueInToken0()).to.be.closeTo(amount0AfterSwap * 2n, amount0AfterSwap * 2n / 100n);
            expect(await vault.estimatedValueInToken1()).to.be.closeTo(amount1AfterSwap * 2n, amount1AfterSwap * 2n / 100n);

            // add more liquidity
            const shares2 = ethers.parseUnits("2", vaultDecimals);
            const totalShares = await vault.totalSupply();
            let token0Amount2 = (assets[0] * shares2 + totalShares - 1n) / totalShares;
            let token1Amount2 = (assets[1] * shares2 + totalShares - 1n) / totalShares;
            token0Amount2 += (token0Amount2 * feeConfig.entryFee + feeMultiplier - 1n) / feeMultiplier;
            token1Amount2 += (token1Amount2 * feeConfig.entryFee + feeMultiplier - 1n) / feeMultiplier;

            // deposit more
            await token0.connect(user).approve(vault, token0Amount2);
            await token1.connect(user).approve(vault, token1Amount2);
            await vault.connect(user).deposit(shares2 * 99n/ 100n, token0Amount2, token1Amount2);

            // reduce some position
            await helpers.time.increase(1000);   // advance some time
            const position = await vault.positions(1);
            await vault.connect(manager).removeLiquidity(position.tickLower, position.tickUpper, position.liquidity, 0, 0, UINT64_MAX);

            // check assets and token values
            assets = await vault.vaultAllUnderlyingAssets();
            const newAmount0 = amount0AfterSwap + token0Amount2;
            const newAmount1 = amount1AfterSwap + token1Amount2;
            expect(assets[0]).to.be.closeTo(newAmount0, newAmount0 / 100n);
            expect(assets[1]).to.be.closeTo(newAmount1, newAmount1 / 100n);

            expect(await vault.estimatedValueInToken0()).to.be.closeTo(newAmount0 * 2n, newAmount0 * 2n / 100n);
            expect(await vault.estimatedValueInToken1()).to.be.closeTo(newAmount1 * 2n, newAmount1 * 2n / 100n);

            // manager swap back, using UniswapV3
            const swapAmount2 = await token1.balanceOf(vault);     
            await vault.connect(manager).inPoolSwap(false, swapAmount2, 0);

            // withdraw
            const amount0Before = await token0.balanceOf(user);
            const amount1Before = await token1.balanceOf(user);
            const userShares = await vault.balanceOf(user);
            expect(await vault.connect(user).withdraw(userShares, 0, 0))
            .to.changeTokenBalance(vault, user, -userShares);
            const amount0After = await token0.balanceOf(user);
            const amount1After = await token1.balanceOf(user);

            // estimate value of received tokens
            const amount0Diff = amount0After - amount0Before;
            const amount1Diff = amount1After - amount1Before;
            const sqrtPriceX96 = poolInfo[7];
            const price = sqrtPriceX96 * sqrtPriceX96;
            const totalIn0 = (amount1Diff << 192n) / price + amount0Diff;

            // expect withdrawn tokens to be > 95% of invested token0
            const investedToken0 = token0AmountWithFee + token0Amount2 + (token1Amount2 << 192n) / price;
            expect(totalIn0).to.be.closeTo(investedToken0, investedToken0 / 50n);

            // remove the remaining share
            const remainShares = await vault.balanceOf(treasury);
            await vault.connect(treasury).withdraw(remainShares, 0, 0);
            expect(await vault.totalSupply()).to.equal(0);

            // positions should be empty
            expect(await vault.getAllPositions()).to.eql([]);
        });
    });
});
