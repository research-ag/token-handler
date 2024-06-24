# TokenHandler

## Overview

TokenHandler is a package designed to facilitate the deposit and withdrawal management on an ICRC-1 ledger. The package allows financial service canisters to effectively track and manage user funds. An example for such a service is a DEX. TokenHandler provides a comprehensive solution for handling ICRC-1 token transactions efficiently and securely.

## Features

- Deposit via direct transfer
- Deposit via an allowance
- Withdrawal mechanism
- Traceable fund flow
- User balance tracking

## Links

The package is published on [MOPS](https://mops.one/token-handler) and [GitHub](https://github.com/research-ag/token-handler).

The API documentation can be found [here](https://mops.one/token-handler/docs/lib) on Mops.

For updates, help, questions, feedback and other requests related to this package join us on:

- [OpenChat group](https://oc.app/2zyqk-iqaaa-aaaar-anmra-cai)
- [Twitter](https://twitter.com/mr_research_ag)
- [Dfinity forum](https://forum.dfinity.org/)

## Build & test

We need up-to-date version of `mops` installed.

Then run:

```
git clone git@github.com:research-ag/token-handler.git
mops install
mops test
```

## Installation

You need `mops` installed. In your project directory run:

```
mops add token-handler
```

In the Motoko source file import the package as:

```
import TokenHandler "mo:token-handler";
```

## Example

To see token-handler package in action, check out the [example code](https://github.com/research-ag/token-handler/blob/main/example). The example is a simple implementation of the [ICRC-84](https://github.com/research-ag/icrc-84) standard.

## Documentation

### Requirements

The only requirement on the underlying token ledger is the ICRC-1 standard. Deposit method via direct transfer is available without ICRC-2 extension. For using the deposit method via an allowance ICRC-2 extension is required.

It is not required that the service can inspect individual deposit transactions by transaction id, memo or other means. Hence, it is not required that the underlying token ledger provides an indexer, transaction history or archive. In particular, the ICRC-3 extension is not required.

### TokenHandler config options

The following table outlines the configuration options available for the `TokenHandler` class constructor:

| Property name | Type | Description |
| --- | --- | --- |
| ledgerApi | LedgerAPI | Object that represents the ledger API. |
| ownPrincipal | Principal | Service principal. |
| initialFee | Nat | Initial fee value. |
| triggerOnNotifications | Bool | Flag that enables scheduling consolidation after a deposit notification. |
| traceableWithdrawal | Bool | Flag that enables traceable withdrawal mode. |
| log | (Principal, LogEvent) -> () | Callback that is used to log events inside the token handler. |

### Deposit via direct transfer

![image](https://github.com/research-ag/token-handler/assets/154005444/cda9c0d8-c54c-4e71-b539-0e45658db2a0)
*Diagram representing the structural specifics of the deposit via direct transfer.*

There are two ways for a user to deposit funds to the service. The first one is via direct transfer to a so-called "deposit account" of the service.

There are two steps required when a user makes a deposit with the direct transfer method:

1. Make a transfer on the underlying ICRC-1 ledger into the personal deposit account (deposit account) under control of the service.
2. Notify the service about the fact that a deposit has been made.

In the direct transfer method, users make deposits into individual deposit accounts which are subaccounts that are derived from the user principal in a deterministic and publicly known way.

The deposit method is balance-based (as opposed to transaction-based). This means it is sufficient that the service can read the balances in the deposit accounts from the underlying token ledger.

After the user has made a transfer to the deposit account and notified the service, consolidation is scheduled. Consolidation is the process by which deposits are processed, that is, deposit funds are transferred from deposit accounts to the main account.

<details>
<summary>Sequence diagram</summary>
<img src="https://github.com/research-ag/token-handler/assets/154005444/9cc7cb16-28eb-4187-a366-3aba7d662368">
</details>

### Deposit via an allowance

![image](https://github.com/research-ag/token-handler/assets/154005444/1f11c43f-4f13-4c79-8094-b18b067f1b5f)
*Diagram representing the structural specifics of the deposit via an allowance.*

An alternative way to make deposits is via allowances.

There are two steps required when a user makes a deposit with the direct transfer method:

1. Approve an allowance to the service.
2. Call the deposit method with the desired amount.

Unlike deposit via direct transfer, deposit via an allowance allows to deposit in 1 step since there is no intermediate step with a deposit account. Accordingly, there is no consolidation and we only have one transfer within the deposit process.

Allowances are simpler to process for the service. Overall transaction fees are lower if an allowance is used for multiple deposits.

But allowances due not always work, for example if:

- the ICRC-1 ledger does not support ICRC-2
- the user's wallet does not support ICRC-2 (currently most wallets)
- the user wants to make a deposit directly from an exchange

<details>
<summary>Sequence diagram</summary>
<img src="[https://github.com/research-ag/token-handler/assets/154005444/c51c5a8e-8ba1-4255-88c3-4bbced6ffaa7](https://github.com/research-ag/token-handler/assets/154005444/584600ec-b35d-464d-b731-4d6b0825ec52)">
</details>

## Withdrawal mechanism

The package provides withdrawal functionality. The standard withdrawal method is a direct transfer from the main account to an arbitrary account specified by the user. The disadvantage of this method is that it becomes impossible to offload tracability of funds to the underlying ICRC-1 ledger.

An alternative option is to use a flag `traceableWithdrawal` when initializing TokenHandler that enables traceable withdrawal mode. This prevents the service to act as a mixer. Without this restriction, the services could potentially be forced to either do KYC or to provide a complete log of its internal transaction, to make the internal flow of funds traceable. However, we want to be able to keep the services as simple as possible. Hence, this restrictions is made to offload all logging to the ICRC-1 ledger.

Withdrawal traceability is achieved by using an intermediate account that is linked to the user. More precisely, before the withdrawal to the recipient's account is made, the funds will be transferred to the deposit account (the one that is also used for deposits), and the withdrawal will already be made from this account.

<details>
<summary>Sequence diagram (traceableWithdrawal=false)</summary>
<img src="https://github.com/research-ag/token-handler/assets/154005444/fbfb5621-8299-4942-aebb-80af326c59ff">
</details>

### API documentation

Full API documentation can be found [here](https://mops.one/token-handler/docs/lib).

## Copyright

MR Research AG, 2023-2024

## Authors

Authors: Timo Hanke (timohanke), Denys Kushnarov (reginleif888), Andy Gura (AndyGura)

## License

Apache-2.0
