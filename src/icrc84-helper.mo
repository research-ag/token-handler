import ICRC1 "icrc1-api";
import ICRC1Agent "icrc1-agent";
import ICRC84 "mo:icrc84";

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

  public class Ledger(api : ICRC1.API, ownPrincipal : Principal, initial_fee : Nat) {
    public var callback : (Nat, Nat) -> () = func(_, _) {};

    let agent = ICRC1Agent.LedgerAgent(api);
    agent.setFee(initial_fee);

    public func fee() : Nat = agent.fee();

    public func setFee(newFee : Nat) {
      let oldFee = agent.fee();
      if (newFee != oldFee) {
        agent.setFee(newFee);
        callback(oldFee, newFee);
      };
    };

    var feeLock = false;
    public func loadFee() : async* ?Nat {
      if (feeLock) return null;
      feeLock := true;
      try {
        switch (await* agent.fetchFee()) {
          case (#ok(fee)) { setFee(fee); ?fee };
          case _ null;
        };
      } finally feeLock := false;
    };

    func checkFee(res : TransferResult or DrawResult) : () {
      switch (res) {
        case (#err(#BadFee { expected_fee })) {
          setFee(expected_fee);
        };
        case _ {};
      };
    };

    /// Fetches actual deposit for a principal from the ICRC1 ledger.
    public func loadDeposit(p : Principal) : async* BalanceResult {
      await* agent.balance_of({
        owner = ownPrincipal;
        subaccount = ?ICRC84.toSubaccount(p);
      });
    };

    // Amount is the amount to transfer out, amount - fee is received
    func transfer(from_subaccount : ?ICRC1.Subaccount, to : ICRC1.Account, amount : Nat) : async* TransferResult {
      let fee = agent.fee();
      assert amount >= fee;
      let res = await* agent.transfer(from_subaccount, to, amount - fee);
      checkFee(res);
      res;
    };

    /// Consolidate funds into the main account
    public func consolidate(p : Principal, amount : Nat) : async* TransferResult {
      await* transfer(
        ?ICRC84.toSubaccount(p),
        { owner = ownPrincipal; subaccount = null },
        amount,
      );
    };

    /// Send <amount> out from the main account, <amount> - fee_ will be received
    public func send(to : ICRC1.Account, amount : Nat) : async* TransferResult {
      await* transfer(null, to, amount);
    };

    /// Draw <amount> from an allowance into the main account
    /// <amount> is the amount including fees subtracted from the allowance
    /// <amount - fee will be received in the main account
    public func draw(p : Principal, from : ICRC1.Account, amount : Nat) : async* DrawResult {
      let fee = agent.fee();
      assert amount >= fee;
      let to = { owner = ownPrincipal; subaccount = null };
      let res = await* agent.transfer_from(from, to, amount - fee, ?ICRC84.toSubaccount(p));
      checkFee(res);
      res;
    };

  };
};
