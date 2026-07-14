import R "mo:core/Result";

import ICRC1 "icrc1-api";

/// This module is built on top of icrc1-api.
/// It wraps the ICRC1 ledger API calls in try-catch blocks
/// and translates all async call errors into Error variants.
/// The purpose is that higher level code does not have to deal with try-catch blocks.
/// Higher level code can make calls to `async*` function that are guaranteed to never throw.
///
/// The module also tries to simplify making the calls.
/// It reduces generality by not allowing `memo` and `created_at_time` to be set.
/// They are always set to `null`.
/// It does not require the `fee` argument to be passed with every call.
/// Instead, `setFee()` can be called once and the provided fee value is then automatically passed along with every call made.
///
/// This module does not parse nor interpret any errors returned from calls.
/// In particular, it does not try to be smart about fees and does not try to auto-detect the ledger fee.
/// It does not deal with race conditions and concurrency issues between ledger calls.
///
/// This module is general-purpose. It is not specific to the TokenHandler.
module {
  public type TransferError = ICRC1.TransferError or {
    #CallIcrc1LedgerError;
  };

  public type TransferFromError = ICRC1.TransferFromError or {
    #CallIcrc1LedgerError;
  };

  public type TransferResult = R.Result<Nat, TransferError>;

  public type TransferFromResult = R.Result<Nat, TransferFromError>;

  public type BalanceResult = R.Result<Nat, { #CallIcrc1LedgerError }>;

  public type FeeResult = R.Result<Nat, { #CallIcrc1LedgerError }>;

  public type LedgerAgent = {
    api : ICRC1.API;
  };

  public func new(api : ICRC1.API) : LedgerAgent {
    {
      api;
    };
  };

  public func fetchFee(self : LedgerAgent) : async* FeeResult {
    try {
      #ok(await self.api.fee());
    } catch (_) {
      #err(#CallIcrc1LedgerError);
    };
  };

  public func balance_of(self : LedgerAgent, a : ICRC1.Account) : async* BalanceResult {
    try {
      #ok(await self.api.balance_of(a));
    } catch (_) {
      #err(#CallIcrc1LedgerError);
    };
  };

  public func transfer(
    self : LedgerAgent,
    from_subaccount : ?ICRC1.Subaccount,
    to : ICRC1.Account,
    amount : Nat,
    fee : Nat,
  ) : async* TransferResult {
    let args = {
      from_subaccount;
      to;
      amount;
      fee = ?fee;
      memo = null;
      created_at_time = null;
    };
    try {
      R.fromUpper(await self.api.transfer(args));
    } catch (_) {
      #err(#CallIcrc1LedgerError);
    };
  };

  public func transfer_from(
    self : LedgerAgent,
    from : ICRC1.Account,
    to : ICRC1.Account,
    amount : Nat,
    spender : ?ICRC1.Subaccount,
    fee : Nat,
  ) : async* TransferFromResult {
    let args = {
      spender_subaccount = spender;
      from;
      to;
      amount;
      fee = ?fee;
      memo = null;
      created_at_time = null;
    };
    try {
      R.fromUpper(await self.api.transfer_from(args));
    } catch (_) {
      #err(#CallIcrc1LedgerError);
    };
  };
};
