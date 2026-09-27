# Vendored dependencies

Plain-file copies (no git submodules), so an offline verifier can build without fetching anything.

| Library | Upstream | Pinned version | Contents kept |
| --- | --- | --- | --- |
| forge-std | https://github.com/foundry-rs/forge-std | v1.16.2 (bf647bd6046f2f7da30d0c2bf435e5c76a780c1b) | `src/`, licences |
| v4-core | https://github.com/Uniswap/v4-core | main @ 46c6834698c48bc4a463a86d8420f4eb1d7f3b75 (2026-04-02; a post-v4.0.0 main commit that ships `src/types/PoolOperation.sol`, which the launch floor tests import) | `src/`, `test/utils/CurrencySettler.sol` (needed by the `src/test` routers), `licenses/` |
| solmate | https://github.com/transmissions11/solmate | 4b47a19038b798b4a33d9749d25e570443520647 (the commit v4-core pins) | `src/`, licence |
| openzeppelin-contracts | https://github.com/OpenZeppelin/openzeppelin-contracts | v5.7.0 (cab19933c33c2ad1d4c7a84864a3601dddfd16f3) | `contracts/`, licence |

Only `ProtocolFees.sol` in v4-core reaches outside v4-core (solmate `Owned`). OpenZeppelin supplies the
ERC-20 base for CBRK and the test mocks.
