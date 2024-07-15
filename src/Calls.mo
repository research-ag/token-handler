import ICRC1 "icrc1-api";
import R "mo:base/Result";
import Util "util";

module {
  public type Account = ICRC1.Account;

  public type Transfer = ICRC1.TransferError or {
    #CallIcrc1LedgerError;
  };
  public type TransferFrom = ICRC1.TransferFromError or {
    #CallIcrc1LedgerError;
  };

  type Result<X, Y> = R.Result<X, Y>;
  public type TransferResult = Result<Nat, Transfer>;
  public type DrawResult = Result<Nat, TransferFrom>;

  public class Ledger(api : ICRC1.API, ownPrincipal : Principal) {
    var fee_ = 0;

    public func fee() : Nat = fee_;
    public func setFee(x : Nat) = fee_ := x;

    /// Fetches actual deposit for a principal from the ICRC1 ledger.
    public func loadDeposit(p : Principal) : async* Nat {
      // TODO try-catch to catch CallLedgerError
      await api.balance_of({
        owner = ownPrincipal;
        subaccount = ?Util.toSubaccount(p);
      });
    };

    // Amount is the amount to transfer out, amount - fee is received
    func transfer(from_subaccount : ?ICRC1.Subaccount, to : Account, amount : Nat) : async* TransferResult {
      assert amount >= fee_;
      let args = {
        from_subaccount;
        to;
        amount = amount - fee_ : Nat;
        fee = ?fee_;
        memo = null;
        created_at_time = null;
      };
      try {
        R.fromUpper(await api.transfer(args));
      } catch (_) {
        #err(#CallIcrc1LedgerError);
      };
    };

    /// Consolidate funds into the main account
    public func consolidate(p : Principal, amount : Nat) : async* TransferResult {
      await* transfer(
        ?Util.toSubaccount(p),
        { owner = ownPrincipal; subaccount = null },
        amount,
      );
    };

    /// Send <amount> out from the main account, <amount> - fee_ will be received
    public func send(to : Account, amount : Nat) : async* TransferResult {
      await* transfer(null, to, amount);
    };

    /// Draw <amount> from an allowance into the main account
    /// <amount> will be received
    public func draw(p : Principal, from : Account, amount : Nat) : async* DrawResult {
      // TODO: change amount to amount - fee
      let args = {
        spender_subaccount = ?Util.toSubaccount(p);
        from;
        to = { owner = ownPrincipal; subaccount = null };
        amount;
        fee = ?fee_;
        memo = null;
        created_at_time = null;
      };
      try {
        R.fromUpper(await api.transfer_from(args));
      } catch (_) {
        #err(#CallIcrc1LedgerError);
      };
    };

  };
};
