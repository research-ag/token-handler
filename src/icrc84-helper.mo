import ICRC84 "mo:icrc-84";

import ICRC1 "icrc1-api";
import ICRC1Agent "icrc1-agent";
import Types "types";

/// This module wraps around the icrc1-agent and further simplifies the arguments
/// for all calls required for ICRC-84 support.
/// For example, deposit subaccounts are accessed simply by principal.
/// The same is true for the beneficiaries of allowances.
/// Furthermore the meaning of amount is changed to be "inclusive" of fees,
/// which better maps to ICRC-84 behaviour.
/// The class in this module also tracks the underlying ledger fee and
/// automatically updates the tracked value if it changes.
/// The functions in this module do not retry any ledger calls if they fail.
module {

  type BalanceResult = ICRC1Agent.BalanceResult;

  type TransferResult = ICRC1Agent.TransferResult;

  type DrawResult = ICRC1Agent.TransferFromResult;

  public type Ledger = Types.Ledger;

  public func Ledger(initial_fee : Nat) : Ledger {
    {
      var fee = initial_fee;
      var feeLock = false;
    };
  };

  public func fee(self : Ledger) : Nat = self.fee;

  public func setFee(self : Ledger, newFee : Nat, ctx : Types.TokenHandlerContext) {
    ignore ctx.assertInvariant();
    let oldFee = self.fee;
    if (newFee != oldFee) {
      self.fee := newFee;
      ctx.onFeeChanged(oldFee, newFee);
    };
    ignore ctx.assertInvariant();
  };

  public func loadFee(self : Ledger, ctx : Types.TokenHandlerContext) : async* ?Nat {
    ignore ctx.assertInvariant();
    if (self.feeLock) return null;
    self.feeLock := true;
    try {
      let ret = switch (await* ICRC1Agent.fetchFee(ctx.api)) {
        case (#ok(fee)) {
          setFee(self, fee, ctx);
          ?fee;
        };
        case _ null;
      };
      ignore ctx.assertInvariant();
      ret;
    } finally self.feeLock := false;
  };

  func checkFee(self : Ledger, res : TransferResult or DrawResult, ctx : Types.TokenHandlerContext) : () {
    switch (res) {
      case (#err(#BadFee { expected_fee })) {
        setFee(self, expected_fee, ctx);
      };
      case _ {};
    };
  };

  /// Fetches actual deposit for a principal from the ICRC1 ledger.
  public func loadDeposit(_self : Ledger, p : Principal, ctx : Types.TokenHandlerContext) : async* BalanceResult {
    ignore ctx.assertInvariant();
    await* ICRC1Agent.balance_of(
      ctx.api,
      {
        owner = ctx.ownPrincipal;
        subaccount = ?ICRC84.toSubaccount(p);
      },
    );
  };

  // Amount is the amount to transfer out, amount - fee is received
  func transfer(self : Ledger, from_subaccount : ?ICRC1.Subaccount, to : ICRC1.Account, amount : Nat, ctx : Types.TokenHandlerContext) : async* TransferResult {
    ignore ctx.assertInvariant();
    assert amount >= self.fee;
    let res = await* ICRC1Agent.transfer(ctx.api, from_subaccount, to, amount - self.fee, self.fee);
    checkFee(self, res, ctx);
    res;
  };

  /// Consolidate funds into the main account
  public func consolidate(self : Ledger, p : Principal, amount : Nat, ctx : Types.TokenHandlerContext) : async* TransferResult {
    ignore ctx.assertInvariant();
    await* transfer(
      self,
      ?ICRC84.toSubaccount(p),
      { owner = ctx.ownPrincipal; subaccount = null },
      amount,
      ctx,
    );
  };

  /// Send <amount> out from the main account, <amount> - fee_ will be received
  public func send(self : Ledger, to : ICRC1.Account, amount : Nat, ctx : Types.TokenHandlerContext) : async* TransferResult {
    ignore ctx.assertInvariant();
    await* transfer(self, null, to, amount, ctx);
  };

  /// Draw <amount> from an allowance into the main account
  /// <amount> is the amount including fees subtracted from the allowance
  /// <amount - fee will be received in the main account
  public func draw(self : Ledger, p : Principal, from : ICRC1.Account, amount : Nat, ctx : Types.TokenHandlerContext) : async* DrawResult {
    ignore ctx.assertInvariant();
    assert amount >= self.fee;
    let to = { owner = ctx.ownPrincipal; subaccount = null };
    let res = await* ICRC1Agent.transfer_from(ctx.api, from, to, amount - self.fee, ?ICRC84.toSubaccount(p), self.fee);
    checkFee(self, res, ctx);
    res;
  };
};
