# citizencoin

A local crypto currency for Brussels.

## Need

Whenever we meet (e.g. every first Wednesday of the month for the Crypto Wednesday), we have to buy beers and/or pizzas and we don't always have cash with us.

We can use SumUp but it takes 1.9% transaction fees. But that doesn't cover the use case of someone ordering pizzas for everyone.
It's crazy that we cannot easily use crypto for such a basic use case.

Here is a project to solve that.

## Goals

- Enable people to use their crypto to buy beers/pizzas at our gatherings
- Make it an education tool to onboard people to crypto and learn about DAOs and quadratic voting/funding (learning by doing)

## Requirements

- It has to be friendly to non crypto people (one of our goals is to onboard new people to crypto. We cannot expect them to learn how to use Metamask. Some will, most won't).
- Power users should be able to move their coins to a proper wallet of their choice
- It has to be decentralized
- As such, it cannot be owned by anyone (and therefore nobody can be held responsible for people using it, and the system can be on working even when key people leave the community)

## Assumptions

- Most wallets won't hold more than €100 equivalent
- Some wallets will be lost or forgotten
- A pin code is enough to protect a wallet
- Some people will want to move their coins to a more secure wallet

## MVP

- People should be able to mint the coins by sending some stable coins ([agEUR](https://www.angle.money)? [cEUR](https://docs.celo.org/learn/platform-native-stablecoins-summary)?)
- People should be able to create a quick wallet by visiting a mobile friendly page to receive those coins (and send them)
  - This requires making sure that we can have gasless transactions or that new accounts receive enough native tokens to pay for fees from a faucet

## Vision

This could be the seed for a new local currency in Brussels that would have built-in a tax system (transaction fees, demurrage fee) and a way to allocate tax money for the good of the community.

## Open questions

- [Which blockchain to use?](https://github.com/daobrussels/citizencoin/issues/1)

## Technical stack

- Solidity (EVM compatible blockchain)
- React Native ([expo](https://expo.dev), [solito](https://github.com/nandorojo/solito))

## Running the tests

```
git clone git@github.com:daobrussels/citizencoin.git
cd citizencoin/smartcontracts
npm install
npm run test
```
