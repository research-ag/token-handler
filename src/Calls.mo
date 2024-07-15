import ICRC1 "icrc1-api";
import ICRC1Calls "icrc1-calls";
import ICRC84 "mo:icrc84";

module {
  type TransferResult = ICRC1Calls.TransferResult;
  type DrawResult = ICRC1Calls.TransferFromResult;

  public class Ledger(api : ICRC1.API, ownPrincipal : Principal) {
    let calls = ICRC1Calls.LedgerCalls(api);
    public func fee() : Nat = calls.fee();
    public func setFee(x : Nat) = calls.setFee(x);

    /// Fetches actual deposit for a principal from the ICRC1 ledger.
    public func loadDeposit(p : Principal) : async* Nat {
      let res = await* calls.balance_of({
        owner = ownPrincipal;
        subaccount = ?ICRC84.toSubaccount(p);
      });
      // TODO change return type to Result type
      switch (res) {
        case (#ok(x)) { x };
        case (#err(_)) { 0 };
      };
    };

    // Amount is the amount to transfer out, amount - fee is received
    func transfer(from_subaccount : ?ICRC1.Subaccount, to : ICRC1.Account, amount : Nat) : async* TransferResult {
      let fee = calls.fee();
      assert amount >= fee;
      await* calls.transfer(from_subaccount, to, amount - fee);
    };

    /// Consolidate funds into the main account
    public func consolidate(p : Principal, amount : Nat) : async* TransferResult {
      await* calls.transfer(
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
    /// <amount> will be received
    public func draw(p : Principal, from : ICRC1.Account, amount : Nat) : async* DrawResult {
      // TODO: change amount to amount - fee
      // let fee = calls.fee();
      // assert amount >= fee;
      let to = { owner = ownPrincipal; subaccount = null };
      await* calls.transfer_from(from, to, amount, ?ICRC84.toSubaccount(p));
    };

  };
};
