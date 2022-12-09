import { expect, use } from "chai";
import { Contract, Signer, BigNumber } from 'ethers';
import { getAddress } from "ethers/lib/utils";
import { ethers, waffle } from "hardhat";
// import { solidity } from "ethereum-waffle";
const { solidity } = waffle;
import { BrusselsCoin } from "../typechain/BrusselsCoin";
import { StableCoin } from "../typechain/StableCoin";
import BigNumberJS from 'bignumber.js';

use(solidity);

const DECIMALS = 18;

const getBigNumber = (bigNumber: BigNumber) => {
  const bg = new BigNumberJS(bigNumber.toHexString());
  return bg.shiftedBy(-18).toNumber();
}

const d = new Date();
const now = Math.round(d.getTime()/1000);

const xMonthsAgo = (x: number) => {
  const d = new Date();
  const now = Math.round(d.getTime()/1000);
  return Math.round(d.setDate(d.getDate() - x * 31) / 1000);
}

const xMonthsFromNow = (x: number) => {
  const d = new Date();
  const now = Math.round(d.getTime()/1000);
  return Math.round(d.setDate(d.getDate() + x * 31) / 1000);
}

const Tokens = (x: number) => ethers.utils.parseUnits(x+'', 18);

describe("Brussels Coin", () => {
  let bc: BrusselsCoin;
  let stableCoin: StableCoin;
  let signers: Signer[];
  let Owner: Signer, FeeCollector: Signer, Leen: Signer, Julien: Signer, Marc: Signer;
  interface Address {
    [index: string ]: string
  };
  const address: Address = {};

  beforeEach(async () => {
    [Owner, FeeCollector, Leen, Julien, Marc] = await ethers.getSigners();
    address['Owner'] = await Owner.getAddress();
    address['FeeCollector'] = await FeeCollector.getAddress();
    address['Leen'] = await Leen.getAddress();
    address['Julien'] = await Julien.getAddress();
    address['Marc'] = await Marc.getAddress();

    // We deploy an ERC20 token to represent the stable coin
    const stableCoinFactory = await ethers.getContractFactory("StableCoin", Owner);
    stableCoin = (await stableCoinFactory.deploy()) as StableCoin;
    await stableCoin.connect(Owner).transfer(address.Leen, Tokens(200));
    await stableCoin.connect(Owner).transfer(address.Julien, Tokens(1000));
    await stableCoin.connect(Owner).transfer(address.Marc, Tokens(1000));
    const factory = await ethers.getContractFactory(
      "BrusselsCoin",
      Owner
    );
    bc = (await factory.deploy(stableCoin.address, address.FeeCollector)) as BrusselsCoin;
    await bc.deployed();
  });
  
    describe("Minting", () => {
      it("Send 10 stable coins to mint citizen coins", async () => {
        await stableCoin.connect(Owner).approve(bc.address, Tokens(10));
        await bc.connect(Owner).mint(Tokens(10));
        const balance1 = await bc.balanceOf(address.Owner);
        expect(getBigNumber(balance1)).to.eq(10);
      });
    });

    describe("Withdraw stable coins", () => {

      beforeEach(async () => {
        // We mint 200 citizen coins by sending 200 stable coins
        await stableCoin.connect(Leen).approve(bc.address, Tokens(200));
        await bc.connect(Leen).mint(Tokens(200));  
        // We withdraw 100 citizen coin back to stable coin
        await bc.connect(Leen).withdraw(Tokens(100))
      });

      it("sender stable coins balance increase by 100", async () => {
        const stableCoinBalance = await stableCoin.balanceOf(address.Leen);
        console.log("Stable coin balance", getBigNumber(stableCoinBalance));
        expect(getBigNumber(stableCoinBalance)).to.eq(100);  
      });

      it("collects 1% withdrawal fee", async () => {
        const feeCollectorBalance = await bc.balanceOf(address.FeeCollector);
        console.log("feeCollectorBalance", getBigNumber(feeCollectorBalance));
        expect(getBigNumber(feeCollectorBalance)).to.eq(1);
      });

      it("sender citizen coin balances decreases by 100 + withdrawal fees", async () => {
        const bcBalance = await bc.connect(Leen).balanceOf(address.Leen);
        console.log("BC coin balance", getBigNumber(bcBalance));
        expect(getBigNumber(bcBalance)).to.eq(99);
      });

    });

    it("Takes a 1% transaction fee", async () => {
      await stableCoin.connect(Leen).approve(bc.address, Tokens(200));
      await bc.connect(Leen).mint(Tokens(200));
      const balanceLeen1 = await bc.balanceOf(address.Leen);
      expect(getBigNumber(balanceLeen1)).to.eq(200);
      await bc.connect(Leen).transfer(address.Julien, Tokens(100));
      const balanceLeen = await bc.balanceOf(address.Leen);
      const balanceJulien = await bc.balanceOf(address.Julien);
      const balanceFeeCollector = await bc.balanceOf(address.FeeCollector);
      expect(getBigNumber(balanceJulien)).to.eq(100);
      expect(getBigNumber(balanceLeen)).to.eq(99);
      expect(getBigNumber(balanceFeeCollector)).to.eq(1);
    });

    it("computes demurrage fee for x periods", async () => {
      const _rateDecimals = 6;
      const rate = 1 * (10**(_rateDecimals - 2));
      const startingAmount = 1000;
      let computedRate, demurragedAmount;
      computedRate = await bc.connect(Owner).computeDemurrageFactor(rate, 1);
      demurragedAmount = computedRate.toNumber() * startingAmount / 10 ** _rateDecimals;
      expect(demurragedAmount).to.eq(990);
      computedRate = await bc.connect(Owner).computeDemurrageFactor(rate, 2);
      demurragedAmount = computedRate.toNumber() * startingAmount / 10 ** _rateDecimals;
      expect(demurragedAmount).to.eq(980.1);
    });

    it("applies demurrage over 1 month", async () => {
      await stableCoin.connect(Julien).approve(bc.address, Tokens(200));
      await bc.connect(Julien).mint(Tokens(200));
      await bc.connect(Owner).setBlockTimestampInTheFuture(xMonthsFromNow(1));
      const balance3 = await bc.balanceOf(address.Julien);
      expect(getBigNumber(balance3)).to.eq(198);
    });

    it("applies demurrage over 6 months", async () => {
      await stableCoin.connect(Julien).approve(bc.address, Tokens(1000));
      await bc.connect(Julien).mint(Tokens(1000));
      const futureTimestamp = xMonthsFromNow(6);
      await bc.connect(Owner).setBlockTimestampInTheFuture(futureTimestamp);
      const balance4 = await bc.balanceOf(address.Julien);
      expect(Math.floor((getBigNumber(balance4)))).to.eq(Math.floor(941)); // 1000 * 0.99^6
    });

    it("does not apply demurrage on newly received money", async () => {
      await stableCoin.connect(Julien).approve(bc.address, Tokens(1000));
      await bc.connect(Julien).mint(Tokens(1000));
      const futureTimestamp = xMonthsFromNow(6);
      await bc.connect(Owner).setBlockTimestampInTheFuture(futureTimestamp);

      await bc.connect(Julien).transfer(address.Leen, Tokens(200));
      const balance5 = await bc.balanceOf(address.Julien);
      expect(Math.floor(getBigNumber(balance5))).to.eq(739); // 941 - 200 - (0.01 * 200)
      const leenBalance = await bc.balanceOf(address.Leen);
      expect(getBigNumber(leenBalance)).to.eq(200);
    });

    it("updates demurrage rate", async () => {
      await stableCoin.connect(Julien).approve(bc.address, Tokens(1000));
      await bc.connect(Julien).mint(Tokens(1000));

      await stableCoin.connect(Marc).approve(bc.address, Tokens(1000));
      await bc.connect(Marc).mint(Tokens(1000));

      await bc.connect(Owner).updateDemurrageRate(20000, xMonthsFromNow(2));
      await bc.connect(Owner).setBlockTimestampInTheFuture(xMonthsFromNow(1));

      await bc.connect(Julien).transfer(address.Leen, Tokens(200));
      let balanceJulien = await bc.balanceOf(address.Julien);
      expect(Math.floor(getBigNumber(balanceJulien))).to.eq(788); // 1000 - (0.01 * 1000 demurrage 1 month) - 200 - (0.01 * 200 fee) = 1000 - 212

      await bc.connect(Owner).setBlockTimestampInTheFuture(xMonthsFromNow(3));

      let balanceMarc = await bc.balanceOf(address.Marc);
      expect(Math.floor(getBigNumber(balanceMarc))).to.eq(960); // 1000 - (1000 * 0.01^2 demurrage 2 months * 0.02 demurrage 1 month) = 1000*0.99*0.99*0.98 = 960

      balanceJulien = await bc.balanceOf(address.Julien);
      expect(Math.floor(getBigNumber(balanceJulien))).to.eq(764); // 788 - (788 * 0.01 demurrage for 1 month * 0.02 demurrage for 1 month) = 788*0.99*0.98 = 764

      await bc.connect(Julien).transfer(address.Leen, Tokens(200));
      balanceJulien = await bc.balanceOf(address.Julien);
      expect(Math.floor(getBigNumber(balanceJulien))).to.eq(562); // 764 - 200 - transaction fee (2)

      const balanceLeen = await bc.balanceOf(address.Leen);
      expect(Math.floor(getBigNumber(balanceLeen))).to.eq(394); // 200 - (200 * 0.01 demurrage for 1 month * 0.02 demurrage for 1 month) = 200*0.99*0.98 = 194 + 200 received

    });

    it("ignores past demurrage rate", async () => {
      await stableCoin.connect(Julien).approve(bc.address, Tokens(1000));
      await bc.connect(Julien).mint(Tokens(1000));
      await bc.connect(Owner).updateDemurrageRate(20000, xMonthsFromNow(1));
      await bc.connect(Owner).setBlockTimestampInTheFuture(xMonthsFromNow(2));

      await bc.connect(Julien).transfer(address.Leen, Tokens(200));      
      await bc.connect(Owner).setBlockTimestampInTheFuture(xMonthsFromNow(4));

      const balanceLeen = await bc.balanceOf(address.Leen);
      expect(Math.floor(getBigNumber(balanceLeen))).to.eq(192); // 200 - (200 * 0.02^2 demurrage for 2 months)

    });

    it("adds the demurrage and transaction fees to the feeCollector account", async () => {
      await stableCoin.connect(Julien).approve(bc.address, Tokens(1000));
      await bc.connect(Julien).mint(Tokens(1000));
      await bc.connect(Owner).setBlockTimestampInTheFuture(xMonthsFromNow(3)); // +1000*0.01^3 demurrage (30)

      let balanceFeeCollector = await bc.balanceOf(address.Owner);
      expect(getBigNumber(balanceFeeCollector)).to.eq(0); // fees are only collected when there is a transaction

      await bc.connect(Julien).transfer(address.Leen, Tokens(200)); // +1000*0.01^3 demurrage (30) +2 transaction fee

      balanceFeeCollector = await bc.balanceOf(address.FeeCollector);
      expect(Math.floor(getBigNumber(balanceFeeCollector))).to.eq(31);
    });

    it("sets the demurrage rate to zero", async () => {
      await stableCoin.connect(Julien).approve(bc.address, Tokens(1000));
      await bc.connect(Julien).mint(Tokens(1000));
      await bc.connect(Owner).updateDemurrageRate(0, xMonthsFromNow(1));
      await bc.connect(Owner).setBlockTimestampInTheFuture(xMonthsFromNow(2));

      await bc.connect(Julien).transfer(address.Leen, Tokens(200));      
      await bc.connect(Owner).setBlockTimestampInTheFuture(xMonthsFromNow(4));

      const balanceLeen = await bc.balanceOf(address.Leen);
      expect(getBigNumber(balanceLeen)).to.eq(200);

    });    
  });
