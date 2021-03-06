[![CircleCI](https://circleci.com/gh/pdlla/arbitragepotato.svg?style=svg)](https://circleci.com/gh/pdlla/arbitragepotato)

# Potato Trader 🥔🥔🥔

Potato Trader is a trading library written in Haskell created for the purpose of bot trading shit coins.

Exchanges and tokens are encoded at the type level to help enforce sensible trading compile time.

For example a token on an exchange is defined by
```
class (Token t, Exchange e) => ExchangeToken t e
```
a trading pair is thus
```
class (ExchangeToken t1 e, ExchangeToken t2 e) => ExchangePair t1 t2 e
```
and given 2 trading pairs, we can arbitrage
```
arbitrage :: (ExchangePair t1 t2 e1, ExchangePair t1 t2 e2) => ...
```

Potato Trader currently supports the following trading algorithms:
- arbitrage
- market maker (needs testing)

And supports the following exchanges:
- Uniswap (on any Web3 compatible blockchain)
- [Bilaxy](https://www.bilaxy.com/)

Once an exchange is implemented, supported tokens and trading pairs must be (easily) added in code to support trading with type safety.

Some planned features that aren't implemented yet:
- accounts are currently read unencrypted from a file directly inside the library. This is solved with `ExchangeAccount` type family but it hasn't been fully integrated yet
- better test cases for effectful code using [test-fixture](https://lexi-lambda.github.io/blog/2017/06/29/unit-testing-effectful-haskell-with-monad-mock/)
  - note that the current tests require a key file and communicate with live exchanges D:
- support for better marketmaker algorithms
  - marketmaker.hs only implements the most basic marketmaker algorithm which is not competitive
  - the current interface to exchange rates uses the uniswap interface and looks something like:
    `sellt1     :: Amount t1 -> Amount t2`
    which is not intended for market making (plus the spread is always negative on uniswap)
  - there needs to be a more fine grained interface for order matching exchanges so that it's possible to write a more competitive market maker
    - it's possible to build such an interface by querying the current interface at many points, which is probably not ideal
