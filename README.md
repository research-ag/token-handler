# token-handler

## Overview

The token-handler package is designed to facilitate the deposit and withdrawal management on an ICRC-1 ledger. The package allows financial service canisters such as DEX to effectively track, credit, and manage user funds. Key features include subaccount management, deposit notifications, credit registry, and withdrawal mechanisms, providing a comprehensive solution for handling ICRC-1 token transactions efficiently and securely.

### Links

The package is published on [MOPS](https://mops.one/token-handler) and [GitHub](https://github.com/research-ag/token-handler).
Please refer to the README on GitHub where it renders properly with formulas and tables.

The API documentation can be found [here](https://mops.one/token-handler/docs/lib) on Mops.

For updates, help, questions, feedback and other requests related to this package join us on:

- [OpenChat group](https://oc.app/2zyqk-iqaaa-aaaar-anmra-cai)
- [Twitter](https://twitter.com/mr_research_ag)
- [Dfinity forum](https://forum.dfinity.org/)

### Motivation

The package was developed to streamline and secure the entire lifecycle of user funds on an ICRC1 ledger, including deposits, credits, and withdrawals.

## Usage

### Install with mops

You need `mops` installed. In your project directory run:

```
mops add token-handler
```

In the Motoko source file import the package as:

```motoko
import TokenHandler "mo:token-handler";
```

### Example

To see token-handler package in action, check out the [example code](https://github.com/research-ag/icrcX/blob/main/example/main.mo).

### Build & test

We need up-to-date versions of `node`, `moc` and `mops` installed.
Suppose `<path-to-moc>` is the path of the `moc` binary of the appropriate version.

Then run:

```
git clone git@github.com:research-ag/token-handler.git
mops install
DFX_MOC_PATH=<path-to-moc> mops test
```

## Copyright

MR Research AG, 2023-2024

## Authors

Main author: Timo Hanke (timohanke)
Contributors: Denys Kushnarov (reginleif888), Andy Gura (AndyGura)

## License

Apache-2.0
