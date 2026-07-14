import ICRC84 "mo:icrc-84";

import ICRC1 "icrc1-api";
import ICRC1Agent "icrc1-agent";

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
  public type StableData = {
    fee : Nat;
  };

  type BalanceResult = ICRC1Agent.BalanceResult;

  type TransferResult = ICRC1Agent.TransferResult;

  type DrawResult = ICRC1Agent.TransferFromResult;

  public type Ledger = {
    agent : ICRC1Agent.LedgerAgent;
    ownPrincipal : Principal;
    var feeLock : Bool;
  };

  public func Ledger(api : ICRC1.API, ownPrincipal : Principal, initial_fee : Nat) : Ledger {
    let agent = ICRC1Agent.new(api);
    ICRC1Agent.setFee(agent, initial_fee);
    {
      agent;
      ownPrincipal;
      var feeLock = false;
    };
  };

  public func fee(self : Ledger) : Nat = self.agent.fee();

  public func setFee(self : Ledger, newFee : Nat, assertInvariant : () -> Bool, onFeeChanged : (oldFee : Nat, newFee : Nat) -> ()) {
    ignore assertInvariant();
    let oldFee = self.agent.fee();
    if (newFee != oldFee) {
      self.agent.setFee(newFee);
      onFeeChanged(oldFee, newFee);
    };
    ignore assertInvariant();
  };

  public func loadFee(self : Ledger, assertInvariant : () -> Bool, onFeeChanged : (oldFee : Nat, newFee : Nat) -> ()) : async* ?Nat {
    ignore assertInvariant();
    if (self.feeLock) return null;
    self.feeLock := true;
    try {
      let ret = switch (await* ICRC1Agent.fetchFee(self.agent)) {
        case (#ok(fee)) { setFee(self, fee, assertInvariant, onFeeChanged); ?fee };
        case _ null;
      };
      ignore assertInvariant();
      ret;
    } finally self.feeLock := false;
  };

  func checkFee(self : Ledger, res : TransferResult or DrawResult, assertInvariant : () -> Bool, onFeeChanged : (oldFee : Nat, newFee : Nat) -> ()) : () {
    switch (res) {
      case (#err(#BadFee { expected_fee })) {
        setFee(self, expected_fee, assertInvariant, onFeeChanged);
      };
      case _ {};
    };
  };

  /// Fetches actual deposit for a principal from the ICRC1 ledger.
  public func loadDeposit(self : Ledger, p : Principal, assertInvariant : () -> Bool) : async* BalanceResult {
    ignore assertInvariant();
    await* ICRC1Agent.balance_of(self.agent, {
      owner = self.ownPrincipal;
      subaccount = ?ICRC84.toSubaccount(p);
    });
  };

  // Amount is the amount to transfer out, amount - fee is received
  func transfer(self : Ledger, from_subaccount : ?ICRC1.Subaccount, to : ICRC1.Account, amount : Nat, assertInvariant : () -> Bool, onFeeChanged : (oldFee : Nat, newFee : Nat) -> ()) : async* TransferResult {
    ignore assertInvariant();
    let fee = self.agent.fee();
    assert amount >= fee;
    let res = await* ICRC1Agent.transfer(self.agent, from_subaccount, to, amount - fee);
    checkFee(self, res, assertInvariant, onFeeChanged);
    res;
  };

  /// Consolidate funds into the main account
  public func consolidate(self : Ledger, p : Principal, amount : Nat, assertInvariant : () -> Bool, onFeeChanged : (oldFee : Nat, newFee : Nat) -> ()) : async* TransferResult {
    ignore assertInvariant();
    await* transfer(
      self,
      ?ICRC84.toSubaccount(p),
      { owner = self.ownPrincipal; subaccount = null },
      amount,
      assertInvariant,
      onFeeChanged,
    );
  };

  /// Send <amount> out from the main account, <amount> - fee_ will be received
  public func send(self : Ledger, to : ICRC1.Account, amount : Nat, assertInvariant : () -> Bool, onFeeChanged : (oldFee : Nat, newFee : Nat) -> ()) : async* TransferResult {
    ignore assertInvariant();
    await* transfer(self, null, to, amount, assertInvariant, onFeeChanged);
  };

  /// Draw <amount> from an allowance into the main account
  /// <amount> is the amount including fees subtracted from the allowance
  /// <amount - fee will be received in the main account
  public func draw(self : Ledger, p : Principal, from : ICRC1.Account, amount : Nat, assertInvariant : () -> Bool, onFeeChanged : (oldFee : Nat, newFee : Nat) -> ()) : async* DrawResult {
    ignore assertInvariant();
    let fee = self.agent.fee();
    assert amount >= fee;
    let to = { owner = self.ownPrincipal; subaccount = null };
    let res = await* ICRC1Agent.transfer_from(self.agent, from, to, amount - fee, ?ICRC84.toSubaccount(p));
    checkFee(self, res, assertInvariant, onFeeChanged);
    res;
  };

  public func share(self : Ledger) : StableData = {
    fee = self.agent.fee();
  };

  public func unshare(self : Ledger, data : StableData) = self.agent.setFee(data.fee);
};
