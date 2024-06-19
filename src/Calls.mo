import ICRC1 "ICRC1";
import R "mo:base/Result";
import Option "mo:base/Option";
import Util "util";

module {
  public type Account = ICRC1.Account;

  public module Error {
    public type Transfer = ICRC1.TransferError or { #CallIcrc1LedgerError };
    public type TransferFrom = ICRC1.TransferFromError or {
      #CallIcrc1LedgerError;
    };
    public type TransferMin = Transfer or { #TooLowQuantity };
    public type TransferFromMin = TransferFrom or { #TooLowQuantity };
    public type Withdraw = TransferMin or { #InsufficientCredit };
  };

  type Result<X, Y> = R.Result<X, Y>;
  public type TransferRes = Result<Nat, Error.Transfer>;
  public type DrawRes = Result<Nat, Error.TransferFrom>;

  public class Ledger(api : ICRC1.LedgerAPI, ownPrincipal : Principal) {
    var fee_ = 0;

    public func fee() : Nat = fee_;
    public func setFee(x : Nat) = fee_ := x;

    /// Fetches actual deposit for a principal from the ICRC1 ledger.
    public func loadDeposit(p : Principal) : async* Nat {
      await api.balance_of({
        owner = ownPrincipal;
        subaccount = ?Util.toSubaccount(p);
      });
    };

    // Amount is the amount to transfer out, amount - fee is received
    func transfer(from_subaccount : ?ICRC1.Subaccount, to : Account, amount : Nat) : async* TransferRes {
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
    public func consolidate(p : Principal, amount : Nat) : async* TransferRes {
      await* transfer(
        ?Util.toSubaccount(p),
        { owner = ownPrincipal; subaccount = null },
        amount,
      );
    };

    /// Send out `amount`, `amount - fee` will be received,
    /// `p` - service subaccount from which the transfer is made
    public func send(p : ?Principal, to : Account, amount : Nat) : async* TransferRes {
      await* transfer(Option.map(p, Util.toSubaccount), to, amount);
    };

    /// Draw <amount> from an allowance into the main account
    /// <amount> will be received
    public func draw(p : Principal, from : Account, amount : Nat) : async* DrawRes {
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
